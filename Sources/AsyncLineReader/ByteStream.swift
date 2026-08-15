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
    var hasStopped = false
    var stopWaiter: CheckedContinuation<(), Never>?
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
    let hadSource = state.withLock { state -> Bool in
      let source = state.source
      state.source = nil
      source?.cancel()
      return source != nil
    }

    // nothing was ever started, so nothing has to stop
    if !hadSource { sourceDidStop() }
  }

  /// Called when the dispatch source has stopped for good and the descriptor is nobody's but
  /// ours again.
  func sourceDidStop() {
    let waiter = state.withLock { state -> CheckedContinuation<(), Never>? in
      state.hasStopped = true
      let waiter = state.stopWaiter
      state.stopWaiter = nil
      return waiter
    }
    waiter?.resume()
  }

  /// Waits for that to have happened.
  func waitUntilStopped() async {
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state -> Bool in
        guard !state.hasStopped else { return true }
        state.stopWaiter = continuation
        return false
      }
      if resumeNow { continuation.resume() }
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
  /// whether the descriptor must be left blocking, and so read a byte at a time
  private let readsOneAtATime: Bool
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

    // A terminal we could not open for ourselves — a process without a controlling terminal, or
    // one given a terminal on standard input alone — is the case the descriptor of our own was
    // meant to avoid. Rather than leave its description non-blocking for the whole session,
    // where somebody else's write could fail, read it one keystroke at a time: a source only
    // fires when there is something there, so a single read cannot block.
    readsOneAtATime = !ownsDescriptor && isatty(fileDescriptor) != 0
  }

  deinit {
    // the cancellation handler installed in start() closes or restores the descriptor, once the
    // source has stopped using it
    input.cancelSource()
  }

  private nonisolated static func openControllingTerminal(like fileDescriptor: CInt) -> CInt? {
    let terminal = open("/dev/tty", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
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

    var savedFlags: CInt?
    if !ownsDescriptor, !readsOneAtATime {
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
      let (bytes, isAtEnd) = Self.readAvailable(
        fileDescriptor: fileDescriptor,
        oneAtATime: readsOneAtATime
      )
      input.append(bytes, isAtEnd: isAtEnd)
      Task { await self.deliver() }
    }
    // Closing the descriptor, or putting its flags back, has to wait until the source has
    // stopped: cancellation is asynchronous, and the handler may be inside a read. Restoring
    // blocking mode underneath a read in flight would park the queue for ever.
    let ownsDescriptor = ownsDescriptor
    let fileDescriptor = fileDescriptor
    source.setCancelHandler { [input] in
      if ownsDescriptor {
        close(fileDescriptor)
      } else if let savedFlags {
        _ = fcntl(fileDescriptor, F_SETFL, savedFlags)
      }
      input.sourceDidStop()
    }

    source.resume()
    input.setSource(source)
  }

  /// Reads everything the descriptor has to offer. This relies on the descriptor being
  /// non-blocking — either one we opened that way, or one `start()` set — so that the loop ends
  /// with EAGAIN rather than waiting for bytes that have not arrived.
  private nonisolated static func readAvailable(
    fileDescriptor: CInt,
    oneAtATime: Bool = false
  ) -> (bytes: [UInt8], isAtEnd: Bool) {
    var bytes = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: oneAtATime ? 1 : 1024)

    while true {
      let count = chunk.withUnsafeMutableBytes {
        read(fileDescriptor, $0.baseAddress, $0.count)
      }

      if count > 0 {
        bytes.append(contentsOf: chunk[0..<count])
        if oneAtATime { return (bytes, false) }
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

  /// Stops reading and waits for the descriptor to be let go: closed, if it was ours, and put
  /// back as it was found if it was not. Bytes already buffered remain available.
  func cancel() async {
    finish()
    resumeWaiter()
    await input.waitUntilStopped()
  }

  private func finish() {
    isFinished = true
    input.cancelSource()
  }
}
