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

// The terminal modes here are the ones linenoise established for a line editor, by way of
// swift-commandlinekit; see the acknowledgements in LICENSE.md.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WinSDK)
import WinSDK
import ucrt
#endif

/// The terminal the line reader edits on: its modes, its size, and somewhere to write to.
public struct Terminal: Sendable {
  public let input: CInt
  public let output: CInt

  #if canImport(WinSDK)
  // ucrt does not name the standard descriptors, but the C runtime numbers them as Unix does
  public static let standard = Terminal(input: 0, output: 1)
  #else
  public static let standard = Terminal(input: STDIN_FILENO, output: STDOUT_FILENO)
  #endif

  public init(input: CInt, output: CInt) {
    self.input = input
    self.output = output
  }

  public var isInteractive: Bool {
    #if canImport(WinSDK)
    // what the editor needs is a console, rather than any character device: NUL is one of those
    // too, and _isatty cannot tell them apart
    isConsole(input) && isConsole(output)
    #else
    isatty(input) != 0 && isatty(output) != 0
    #endif
  }

  /// The width in columns, defaulting to 80 if the terminal will not say.
  public var width: Int {
    #if canImport(WinSDK)
    var info = CONSOLE_SCREEN_BUFFER_INFO()
    guard let handle = fileHandle(for: output),
          GetConsoleScreenBufferInfo(handle, &info) else { return 80 }
    // the window rather than the buffer: the buffer is usually the taller of the two, and on
    // the older console the wider as well
    let columns = Int(info.srWindow.Right) - Int(info.srWindow.Left) + 1
    return columns > 0 ? columns : 80
    #else
    var size = winsize()
    guard ioctl(output, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return 80 }
    return Int(size.ws_col)
    #endif
  }

  #if canImport(WinSDK)
  func emit(_ string: String) {
    guard let handle = fileHandle(for: output) else { return }
    let bytes = Array(string.utf8)
    var offset = 0
    while offset < bytes.count {
      var written: DWORD = 0
      let wrote = bytes[offset...].withUnsafeBytes {
        WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil)
      }
      // an escape sequence written by halves would be seen as text, so a short write is taken
      // up again from where it left off; anything else there is no recovering from
      guard wrote, written > 0 else { break }
      offset += Int(written)
    }
  }
  #else
  func emit(_ string: String) {
    let bytes = Array(string.utf8)
    var offset = 0
    var attempts = 0
    let yieldAttempts = 16
    // sixteen yields and then a millisecond apiece: a quarter of a second of grace in all
    let maximumAttempts = 256
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes {
        write(output, $0.baseAddress, $0.count)
      }
      if count > 0 {
        offset += count
        attempts = 0
      } else if count < 0, errno == EINTR {
        // an escape sequence written by halves would be seen as text, so keep trying
        continue
      } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK, attempts < maximumAttempts {
        // Somebody else has made this descriptor non-blocking — the reader no longer does. Give
        // the terminal time to drain, but in small pieces: this runs on a thread of the
        // concurrency pool, which must not be parked for long.
        attempts += 1
        if attempts < yieldAttempts {
          sched_yield()
        } else {
          var pause = timespec(tv_sec: 0, tv_nsec: 1_000_000)
          nanosleep(&pause, nil)
        }
        continue
      } else {
        break
      }
    }
  }
  #endif
}

/// The settings a terminal was found with, so that they can be put back afterwards: a program
/// that exits leaving the terminal in raw mode leaves the shell it was run from unusable.
public struct TerminalSettings: Sendable {
  #if canImport(WinSDK)
  let inputMode: DWORD
  let outputMode: DWORD
  let inputCodePage: UINT
  let outputCodePage: UINT
  #else
  let attributes: termios
  #endif
}

public extension Terminal {
  /// The settings the terminal has at the moment, or nil if it is not a terminal.
  var settings: TerminalSettings? {
    TerminalMode.current(self)
  }

  /// Puts settings taken earlier back.
  func restore(_ settings: TerminalSettings) {
    TerminalMode.restore(self, to: settings)
  }
}

#if canImport(WinSDK)

/// The console modes the line reader needs, and the ones it found.
///
/// The console does here what a Unix terminal driver does: with virtual terminal input turned on
/// it delivers, for the cursor and function keys, the very escape sequences the decoder already
/// understands, so it is only the way the modes are set that differs.
enum TerminalMode {
  static func current(_ terminal: Terminal) -> TerminalSettings? {
    var inputMode: DWORD = 0
    var outputMode: DWORD = 0
    guard let input = fileHandle(for: terminal.input),
          let output = fileHandle(for: terminal.output),
          GetConsoleMode(input, &inputMode), GetConsoleMode(output, &outputMode)
    else { return nil }

    return TerminalSettings(
      inputMode: inputMode,
      outputMode: outputMode,
      inputCodePage: GetConsoleCP(),
      outputCodePage: GetConsoleOutputCP()
    )
  }

  /// Character at a time input, no echo, and no signal or flow control processing: the reader
  /// interprets Ctrl-C and Ctrl-D itself, so that a caller can distinguish them.
  static func makeRaw(_ terminal: Terminal) -> TerminalSettings? {
    guard let saved = current(terminal), let input = fileHandle(for: terminal.input)
    else { return nil }

    var mode = saved.inputMode
    // ENABLE_PROCESSED_INPUT is what turns Ctrl-C into a signal; the window and mouse records
    // would otherwise sit in the queue in front of the keystrokes
    mode &= ~DWORD(
      ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT | ENABLE_MOUSE_INPUT |
        ENABLE_WINDOW_INPUT
    )
    mode |= DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT)
    guard SetConsoleMode(input, mode) else { return nil }

    prepareOutput(terminal, from: saved)
    return saved
  }

  /// Character at a time input with echo and signals left alone, for watching for a keystroke
  /// whilst a command produces output of its own.
  static func makeCharacterAtATime(_ terminal: Terminal) -> TerminalSettings? {
    guard let saved = current(terminal), let input = fileHandle(for: terminal.input)
    else { return nil }

    var mode = saved.inputMode
    mode &= ~DWORD(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT)
    mode |= DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT)
    guard SetConsoleMode(input, mode) else { return nil }

    prepareOutput(terminal, from: saved)
    return saved
  }

  /// Escape sequences on the way out, and UTF-8 in both directions: the console decodes what it
  /// is given, and encodes what it reads, in the code page it is set to, and everything here is
  /// written and read as UTF-8.
  private static func prepareOutput(_ terminal: Terminal, from saved: TerminalSettings) {
    if let output = fileHandle(for: terminal.output) {
      SetConsoleMode(
        output,
        saved.outputMode | DWORD(ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING)
      )
    }
    SetConsoleCP(UINT(CP_UTF8))
    SetConsoleOutputCP(UINT(CP_UTF8))
  }

  static func restore(_ terminal: Terminal, to saved: TerminalSettings) {
    if let input = fileHandle(for: terminal.input) {
      SetConsoleMode(input, saved.inputMode)
    }
    if let output = fileHandle(for: terminal.output) {
      SetConsoleMode(output, saved.outputMode)
    }
    SetConsoleCP(saved.inputCodePage)
    SetConsoleOutputCP(saved.outputCodePage)
  }
}

#else

/// The terminal modes the line reader needs, and the ones it found.
enum TerminalMode {
  static func current(_ terminal: Terminal) -> TerminalSettings? {
    var attributes = termios()
    guard tcgetattr(terminal.input, &attributes) == 0 else { return nil }
    return TerminalSettings(attributes: attributes)
  }

  /// Character at a time input, no echo, and no signal or flow control processing: the reader
  /// interprets Ctrl-C and Ctrl-D itself, so that a caller can distinguish them.
  static func makeRaw(_ terminal: Terminal) -> TerminalSettings? {
    guard let saved = current(terminal) else { return nil }

    var raw = saved.attributes
    raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
    raw.c_oflag &= ~tcflag_t(OPOST)
    raw.c_cflag |= tcflag_t(CS8)
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
    withUnsafeMutablePointer(to: &raw.c_cc) {
      $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { controlCharacters in
        controlCharacters[Int(VMIN)] = 1
        controlCharacters[Int(VTIME)] = 0
      }
    }

    guard tcsetattr(terminal.input, TCSADRAIN, &raw) == 0 else { return nil }
    return saved
  }

  /// Character at a time input with echo and signals left alone, for watching for a keystroke
  /// whilst a command produces output of its own.
  static func makeCharacterAtATime(_ terminal: Terminal) -> TerminalSettings? {
    guard let saved = current(terminal) else { return nil }

    var raw = saved.attributes
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
    withUnsafeMutablePointer(to: &raw.c_cc) {
      $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { controlCharacters in
        controlCharacters[Int(VMIN)] = 1
        controlCharacters[Int(VTIME)] = 0
      }
    }

    guard tcsetattr(terminal.input, TCSANOW, &raw) == 0 else { return nil }
    return saved
  }

  static func restore(_ terminal: Terminal, to saved: TerminalSettings) {
    var attributes = saved.attributes
    tcsetattr(terminal.input, TCSAFLUSH, &attributes)
  }
}

#endif

enum Ansi {
  static let bell = "\u{07}"
  static let eraseToEndOfLine = "\u{1B}[0K"
  static let eraseToEndOfScreen = "\u{1B}[0J"
  static let carriageReturn = "\r"

  static func setColumn(_ column: Int) -> String {
    "\u{1B}[\(column)G"
  }

  static func moveDown(_ rows: Int) -> String {
    rows > 0 ? "\u{1B}[\(rows)B" : ""
  }

  static func moveUp(_ rows: Int) -> String {
    rows > 0 ? "\u{1B}[\(rows)A" : ""
  }
}
