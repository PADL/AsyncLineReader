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
import Synchronization

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the dispatch source has read, and the source itself. Both live outside the actor: the
/// source appends under a lock in arrival order rather than hopping to the actor, where the order
/// would be decided by whichever hop ran first, and holding the source here lets it be cancelled
/// when the stream goes away.
private final class Input: Sendable {
  private struct State {
    var bytes = [UInt8]()
    var isAtEnd = false
    var source: (any DispatchSourceRead)?
  }

  private let state = Mutex(State())

  func append(_ newBytes: [UInt8], isAtEnd: Bool) {
    state.withLock {
      $0.bytes.append(contentsOf: newBytes)
      $0.isAtEnd = $0.isAtEnd || isAtEnd
    }
  }

  /// Takes everything read so far. End of file is reported once, like the bytes are.
  func take() -> (bytes: [UInt8], isAtEnd: Bool) {
    state.withLock { state in
      let taken = (state.bytes, state.isAtEnd)
      state.bytes = []
      state.isAtEnd = false
      return taken
    }
  }

  func discard() {
    state.withLock { $0.bytes = [] }
  }

  func setSource(_ source: (any DispatchSourceRead)?) {
    state.withLock { $0.source = source }
  }

  func cancelSource() {
    state.withLock {
      $0.source?.cancel()
      $0.source = nil
    }
  }

  var hasSource: Bool {
    state.withLock { $0.source != nil }
  }
}

/// Delivers the bytes of a file descriptor to an async consumer, without a thread parked in
/// `read(2)`: a dispatch source does the reading, and buffers whatever the consumer is not yet
/// ready for.
///
/// A stream has a single consumer. Bytes that arrive whilst nobody is waiting, or after a read
/// has timed out, are buffered rather than dropped.
actor ByteStream {
  private let fileDescriptor: CInt
  /// whether the descriptor is ours to make non-blocking, and to close
  private let ownsDescriptor: Bool
  private var savedFlags: CInt?
  private let queue = DispatchQueue(label: "com.padl.AsyncLineReader.input", qos: .userInteractive)
  private let input = Input()
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

  /// Reading without blocking needs O_NONBLOCK, which belongs to the open file description
  /// rather than to the descriptor — and a terminal's is shared with standard output and error,
  /// where making it non-blocking makes somebody else's write fail. So when the descriptor is a
  /// terminal, open the controlling terminal again to get a description of our own; the terminal
  /// settings, which are per device, are unaffected.
  init(fileDescriptor: CInt) {
    if isatty(fileDescriptor) != 0, let own = Self.openControllingTerminal(like: fileDescriptor) {
      self.fileDescriptor = own
      ownsDescriptor = true
    } else {
      self.fileDescriptor = fileDescriptor
      ownsDescriptor = false
    }
  }

  deinit {
    input.cancelSource()
    if ownsDescriptor {
      close(fileDescriptor)
    } else if let savedFlags {
      _ = fcntl(fileDescriptor, F_SETFL, savedFlags)
    }
  }

  private nonisolated static func openControllingTerminal(like fileDescriptor: CInt) -> CInt? {
    let terminal = open("/dev/tty", O_RDONLY | O_NONBLOCK)
    guard terminal >= 0 else { return nil }

    // only if it is the same terminal: standard input may have been redirected to another one
    var own = stat()
    var given = stat()
    guard fstat(terminal, &own) == 0, fstat(fileDescriptor, &given) == 0,
          own.st_rdev == given.st_rdev
    else {
      close(terminal)
      return nil
    }

    return terminal
  }

  private func start() {
    guard !input.hasSource, !isFinished else { return }

    if !ownsDescriptor {
      let flags = fcntl(fileDescriptor, F_GETFL)
      if flags >= 0, flags & O_NONBLOCK == 0 {
        savedFlags = flags
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
      }
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
    source.setEventHandler { [weak self, input, fileDescriptor] in
      guard let self else {
        // nobody is listening any more; leave the descriptor alone rather than reading bytes
        // that belong to whoever holds it next
        input.cancelSource()
        return
      }
      let (bytes, isAtEnd) = Self.read(fileDescriptor: fileDescriptor)
      input.append(bytes, isAtEnd: isAtEnd)
      Task { await self.deliver() }
    }
    source.resume()
    input.setSource(source)
  }

  /// Reads what the descriptor has to offer, without making it non-blocking to do so: the flag
  /// belongs to the open file description, which a terminal shares between standard input,
  /// output and error, so setting it even briefly can make somebody else's write fail. Asking
  /// how much is there first means each read is one the source has already promised will not
  /// block.
  private nonisolated static func read(
    fileDescriptor: CInt
  ) -> (bytes: [UInt8], isAtEnd: Bool) {
    var bytes = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 1024)

    while true {
      let count = chunk.withUnsafeMutableBytes {
        Glibc.read(fileDescriptor, $0.baseAddress, $0.count)
      }

      if count > 0 {
        bytes.append(contentsOf: chunk[0..<count])
      } else if count == 0 {
        return (bytes, true)
      } else if errno == EINTR {
        continue
      } else {
        // nothing more to read for now; anything other than that is the end
        return (bytes, errno != EAGAIN && errno != EWOULDBLOCK)
      }
    }
  }

  /// Moves whatever has been read into the buffer. A consumer is only woken if this brought
  /// something for it: an empty delivery, which happens when the consumer got there first, must
  /// not be mistaken for end of file.
  private func deliver() {
    let (bytes, isAtEnd) = input.take()
    buffer.append(contentsOf: bytes)

    if isAtEnd {
      finish()
    }

    if !bytes.isEmpty || isAtEnd {
      resumeWaiter()
    }
  }

  private func resumeWaiter() {
    guard let waiter else { return }
    self.waiter = nil
    generation += 1
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

  /// Discards anything already read but not yet consumed, wherever it is waiting.
  func flush() {
    buffer.removeAll()
    input.discard()
  }

  /// Stops reading. Bytes already buffered remain available.
  func cancel() {
    finish()
    resumeWaiter()
  }

  private func finish() {
    isFinished = true
    input.cancelSource()
    if !ownsDescriptor, let savedFlags {
      _ = fcntl(fileDescriptor, F_SETFL, savedFlags)
      self.savedFlags = nil
    }
  }
}
