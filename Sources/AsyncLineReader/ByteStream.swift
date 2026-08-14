//
// Copyright (c) 2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

@preconcurrency import Dispatch
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Delivers the bytes of a file descriptor to an async consumer, without a thread parked in
/// `read(2)`: a dispatch source does the reading, and buffers whatever the consumer is not yet
/// ready for.
///
/// A stream has a single consumer. Bytes that arrive whilst nobody is waiting, or after a read
/// has timed out, are buffered rather than dropped.
/// Bytes read from the descriptor before the consumer asked for them. The dispatch source
/// appends under a lock rather than hopping to the actor, so that chunks cannot be reordered by
/// the order the hops happen to run in.
private final class PendingBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = [UInt8]()
  private var isAtEnd = false

  func append(_ newBytes: [UInt8], isAtEnd: Bool) {
    lock.lock()
    defer { lock.unlock() }
    bytes.append(contentsOf: newBytes)
    self.isAtEnd = self.isAtEnd || isAtEnd
  }

  func take() -> (bytes: [UInt8], isAtEnd: Bool) {
    lock.lock()
    defer { lock.unlock() }
    let taken = bytes
    bytes = []
    return (taken, isAtEnd)
  }
}

actor ByteStream {
  private let fileDescriptor: CInt
  private let queue = DispatchQueue(label: "com.padl.AsyncLineReader.input", qos: .userInteractive)
  private let pending = PendingBytes()
  private var source: (any DispatchSourceRead)?
  private var buffer = [UInt8]()
  private var waiter: CheckedContinuation<(), Never>?
  private var isFinished = false
  /// distinguishes the wait a timeout was started for from any later one
  private var generation = 0

  /// True once the file descriptor has reached end of file and everything read from it has been
  /// consumed.
  var isAtEnd: Bool {
    isFinished && buffer.isEmpty
  }

  init(fileDescriptor: CInt) {
    self.fileDescriptor = fileDescriptor
  }

  private func start() {
    guard source == nil, !isFinished else { return }

    let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
    source.setEventHandler { [weak self, pending, fileDescriptor] in
      let (bytes, isAtEnd) = Self.drain(fileDescriptor: fileDescriptor)
      pending.append(bytes, isAtEnd: isAtEnd)
      guard let self else { return }
      Task { await self.deliver() }
    }
    source.resume()
    self.source = source
  }

  /// Reads everything the descriptor has to offer, stopping at end of file or when it would
  /// block.
  ///
  /// Reading without blocking needs O_NONBLOCK, which is a property of the open file description
  /// and so is shared with whoever else holds it — the shell that started us, for one. It is
  /// therefore set for the duration of the read and put back afterwards, rather than left on.
  private nonisolated static func drain(
    fileDescriptor: CInt
  ) -> (bytes: [UInt8], isAtEnd: Bool) {
    let savedFlags = fcntl(fileDescriptor, F_GETFL)
    if savedFlags >= 0, savedFlags & O_NONBLOCK == 0 {
      _ = fcntl(fileDescriptor, F_SETFL, savedFlags | O_NONBLOCK)
    }
    defer {
      if savedFlags >= 0, savedFlags & O_NONBLOCK == 0 {
        _ = fcntl(fileDescriptor, F_SETFL, savedFlags)
      }
    }

    var bytes = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 1024)

    while true {
      let count = chunk.withUnsafeMutableBytes {
        read(fileDescriptor, $0.baseAddress, $0.count)
      }

      if count > 0 {
        bytes.append(contentsOf: chunk[0..<count])
      } else if count == 0 {
        return (bytes, true)
      } else if errno == EINTR {
        continue
      } else {
        // nothing more to read for now; anything else is treated as the end
        return (bytes, errno != EAGAIN && errno != EWOULDBLOCK)
      }
    }
  }

  private func deliver() {
    let (bytes, isAtEnd) = pending.take()
    buffer.append(contentsOf: bytes)
    if isAtEnd {
      finish()
    }
    resumeWaiter()
  }

  private func resumeWaiter() {
    generation += 1
    guard let waiter else { return }
    self.waiter = nil
    waiter.resume()
  }

  /// Returns the next byte, or nil at end of file, if the calling task is cancelled, or if
  /// `timeout` elapses first.
  func next(timeout: Duration? = nil) async -> UInt8? {
    start()
    deliver()

    if buffer.isEmpty, !isFinished, !Task.isCancelled {
      let generation = generation
      let timer: Task<(), Never>? = timeout.map { timeout in
        Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
          } catch {
            // cancelled: the wait it belonged to has already ended
            return
          }
          await self?.expire(generation)
        }
      }
      defer { timer?.cancel() }

      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled {
            continuation.resume()
          } else {
            waiter = continuation
          }
        }
      } onCancel: {
        Task { await self.expire(generation) }
      }
    }

    return buffer.isEmpty ? nil : buffer.removeFirst()
  }

  /// Ends the wait `generation` was taken for, if it is still the current one. A later waiter is
  /// left alone: it has its own timeout.
  private func expire(_ generation: Int) {
    guard generation == self.generation else { return }
    resumeWaiter()
  }

  /// Returns a byte to the head of the stream, so that a decoder can look ahead by one.
  func unread(_ byte: UInt8) {
    buffer.insert(byte, at: 0)
  }

  /// Discards anything already read but not yet consumed.
  func flush() {
    buffer.removeAll()
  }

  /// Stops reading. Bytes already buffered remain available.
  func cancel() {
    finish()
    resumeWaiter()
  }

  private func finish() {
    isFinished = true
    source?.cancel()
    source = nil
  }
}
