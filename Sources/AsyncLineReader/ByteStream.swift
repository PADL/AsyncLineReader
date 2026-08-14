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
actor ByteStream {
  private let fileDescriptor: CInt
  private let queue = DispatchQueue(label: "com.padl.AsyncLineReader.input", qos: .userInteractive)
  private var source: (any DispatchSourceRead)?
  private var buffer = [UInt8]()
  private var waiter: CheckedContinuation<(), Never>?
  private var isFinished = false
  private var savedFlags: CInt?

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

    // the handler drains the descriptor in one go, which needs it to be non-blocking: that is
    // also the only way to see end of file, as a read source is not woken by it on all platforms
    let flags = fcntl(fileDescriptor, F_GETFL)
    if flags >= 0, flags & O_NONBLOCK == 0 {
      savedFlags = flags
      _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let (bytes, isAtEnd) = Self.drain(fileDescriptor: fileDescriptor)
      Task { await self.deliver(bytes, isAtEnd: isAtEnd) }
    }
    source.resume()
    self.source = source
  }

  /// Reads everything the descriptor has to offer, stopping at end of file or when it would
  /// block.
  private nonisolated static func drain(
    fileDescriptor: CInt
  ) -> (bytes: [UInt8], isAtEnd: Bool) {
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

  private func deliver(_ bytes: [UInt8], isAtEnd: Bool) {
    buffer.append(contentsOf: bytes)
    if isAtEnd {
      finish()
    }
    resumeWaiter()
  }

  private func resumeWaiter() {
    guard let waiter else { return }
    self.waiter = nil
    waiter.resume()
  }

  /// Returns the next byte, or nil at end of file or if `timeout` elapses first.
  func next(timeout: Duration? = nil) async -> UInt8? {
    start()

    if buffer.isEmpty, !isFinished {
      let timer: Task<(), Never>? = timeout.map { timeout in
        Task { [weak self] in
          try? await Task.sleep(for: timeout)
          await self?.expire()
        }
      }
      defer { timer?.cancel() }

      await withCheckedContinuation { continuation in
        waiter = continuation
      }
    }

    return buffer.isEmpty ? nil : buffer.removeFirst()
  }

  private func expire() {
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
    if let savedFlags {
      _ = fcntl(fileDescriptor, F_SETFL, savedFlags)
      self.savedFlags = nil
    }
  }
}
