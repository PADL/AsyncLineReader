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

#if canImport(WinSDK)

import Foundation
import Synchronization
import ucrt
import WinSDK

/// The handle behind a C runtime file descriptor, which is what the rest of the reader is
/// written in terms of.
func fileHandle(for fileDescriptor: CInt) -> HANDLE? {
  let raw = _get_osfhandle(fileDescriptor)
  // -1 is a descriptor that was never open, -2 one of a process without a console
  guard raw != -1, raw != -2 else { return nil }
  let handle = HANDLE(bitPattern: UInt(bitPattern: Int(raw)))
  return handle == INVALID_HANDLE_VALUE ? nil : handle
}

/// Whether a descriptor is a console, rather than a file, a pipe, or one of the other character
/// devices that `_isatty` also accepts.
func isConsole(_ fileDescriptor: CInt) -> Bool {
  var mode: DWORD = 0
  guard let handle = fileHandle(for: fileDescriptor) else { return false }
  return GetConsoleMode(handle, &mode)
}

/// Reads a descriptor on a thread of its own and hands what it finds to a `ByteStream`.
///
/// Windows has no equivalent of a dispatch read source: what waits differs with what is being
/// read, and none of it can be waited on from the concurrency pool. So a thread does the waiting,
/// and is careful never to sit in a read that nothing will finish — the console is asked what is
/// in its queue before a keystroke is read, and a pipe how much it holds — so that the thread is
/// always somewhere it can be told to stop from.
final class InputReader: @unchecked Sendable {
  private enum Kind {
    /// a console, whose queue holds records rather than bytes
    case console
    /// a pipe, which can be asked how much it has without taking it
    case pipe
    /// a file, or anything else a read returns from at once
    case file
  }

  private let handle: HANDLE
  private let kind: Kind
  private let input: Input
  private let deliver: @Sendable () -> Void
  /// woken when the reader is to stop, so that a wait ends there and then
  private let stopping: HANDLE
  private let isCancelled = Atomic<Bool>(false)

  /// how long a pipe with nothing in it is left before it is looked at again
  private static let pollInterval: DWORD = 5

  init?(fileDescriptor: CInt, input: Input, deliver: @escaping @Sendable () -> Void) {
    guard let handle = fileHandle(for: fileDescriptor),
          let stopping = CreateEventW(nil, true, false, nil)
    else { return nil }

    self.handle = handle
    self.input = input
    self.deliver = deliver
    self.stopping = stopping

    var mode: DWORD = 0
    if GetConsoleMode(handle, &mode) {
      kind = .console
    } else if GetFileType(handle) == FILE_TYPE_PIPE {
      kind = .pipe
    } else {
      kind = .file
    }
  }

  deinit {
    CloseHandle(stopping)
  }

  func start() {
    let thread = Thread { [self] in run() }
    thread.name = "com.padl.AsyncLineReader.input"
    thread.stackSize = 128 * 1024
    thread.start()
  }

  /// Stops the thread and returns without waiting for it: whoever wants to know when the
  /// descriptor has been let go waits on the input for that.
  func cancel() {
    guard !isCancelled.exchange(true, ordering: .sequentiallyConsistent) else { return }
    SetEvent(stopping)
    // a read of a pipe or a file may already have begun, and this is what ends it; a console
    // read is not begun until there is a keystroke waiting for it
    CancelIoEx(handle, nil)
  }

  private var wasCancelled: Bool {
    isCancelled.load(ordering: .sequentiallyConsistent)
  }

  private func run() {
    // however the loop below leaves off, the descriptor is nobody's but the stream's again, and
    // a cancel waiting to hear that must not be left waiting
    defer { input.sourceDidStop() }

    var buffer = [UInt8](repeating: 0, count: 1024)

    while !wasCancelled {
      switch kind {
      case .console:
        guard waitForKeystroke() else { continue }
      case .pipe:
        guard let available = bytesInPipe() else { return reportEndOfInput() }
        if available == 0 {
          guard WaitForSingleObject(stopping, Self.pollInterval) == WAIT_TIMEOUT else { return }
          continue
        }
      case .file:
        break
      }

      var count: DWORD = 0
      let read = buffer.withUnsafeMutableBytes {
        ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil)
      }

      guard read, count > 0 else {
        // a read cancelled from under us is the reader stopping, not the input ending
        if !wasCancelled { reportEndOfInput() }
        return
      }

      input.append(Array(buffer[0..<Int(count)]), isAtEnd: false)
      deliver()
    }
  }

  private func reportEndOfInput() {
    input.append([], isAtEnd: true)
    deliver()
  }

  /// Waits until the console has something a read would return, which is not the same as having
  /// something in its queue: a key going up, the window being resized or gaining focus, all
  /// leave a record there that a read passes over. Those are taken out of the queue here, so
  /// that the wait does not fire on them again for as long as they sit at its head.
  ///
  /// Returns false if there is nothing to read after all, so that the caller waits again.
  private func waitForKeystroke() -> Bool {
    var handles: [HANDLE?] = [handle, stopping]
    let waited = handles.withUnsafeMutableBufferPointer {
      WaitForMultipleObjects(2, $0.baseAddress, false, INFINITE)
    }
    guard waited == WAIT_OBJECT_0 else { return false }

    var pending: DWORD = 0
    guard GetNumberOfConsoleInputEvents(handle, &pending), pending > 0 else { return false }

    var records = [INPUT_RECORD](repeating: INPUT_RECORD(), count: Int(min(pending, 64)))
    var peeked: DWORD = 0
    guard PeekConsoleInputW(handle, &records, DWORD(records.count), &peeked), peeked > 0
    else { return false }

    for record in records[0..<Int(peeked)] where Self.isTypedKey(record) { return true }

    var discarded: DWORD = 0
    ReadConsoleInputW(handle, &records, peeked, &discarded)
    return false
  }

  /// Whether a record is a keystroke that a read would return bytes for.
  private static func isTypedKey(_ record: INPUT_RECORD) -> Bool {
    guard record.EventType == WORD(KEY_EVENT), record.Event.KeyEvent.bKeyDown.boolValue
    else { return false }
    // a modifier pressed on its own produces nothing, and a read would wait for the key it is
    // there to modify
    return !modifiers.contains(record.Event.KeyEvent.wVirtualKeyCode)
  }

  private static let modifiers: Swift.Set<WORD> = [
    WORD(VK_SHIFT), WORD(VK_CONTROL), WORD(VK_MENU), WORD(VK_CAPITAL), WORD(VK_LWIN),
    WORD(VK_RWIN), WORD(VK_NUMLOCK), WORD(VK_SCROLL),
  ]

  /// How much the pipe is holding, or nil if the far end has gone.
  private func bytesInPipe() -> DWORD? {
    var available: DWORD = 0
    guard PeekNamedPipe(handle, nil, 0, nil, &available, nil) else { return nil }
    return available
  }
}

#endif
