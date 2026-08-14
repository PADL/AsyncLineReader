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
#endif

/// The terminal the line reader edits on: its modes, its size, and somewhere to write to.
public struct Terminal: Sendable {
  public let input: CInt
  public let output: CInt

  public static let standard = Terminal(input: STDIN_FILENO, output: STDOUT_FILENO)

  public init(input: CInt, output: CInt) {
    self.input = input
    self.output = output
  }

  public var isInteractive: Bool {
    isatty(input) != 0 && isatty(output) != 0
  }

  /// The width in columns, defaulting to 80 if the terminal will not say.
  public var width: Int {
    var size = winsize()
    guard ioctl(output, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return 80 }
    return Int(size.ws_col)
  }

  func emit(_ string: String) {
    let bytes = Array(string.utf8)
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes {
        write(output, $0.baseAddress, $0.count)
      }
      guard count > 0 else { break }
      offset += count
    }
  }
}

/// The terminal modes the line reader needs, and the ones it found.
enum TerminalMode {
  /// Character at a time input, no echo, and no signal or flow control processing: the reader
  /// interprets Ctrl-C and Ctrl-D itself, so that a caller can distinguish them.
  static func makeRaw(_ terminal: Terminal) -> termios? {
    var saved = termios()
    guard tcgetattr(terminal.input, &saved) == 0 else { return nil }

    var raw = saved
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
  static func makeCharacterAtATime(_ terminal: Terminal) -> termios? {
    var saved = termios()
    guard tcgetattr(terminal.input, &saved) == 0 else { return nil }

    var raw = saved
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

  static func restore(_ terminal: Terminal, to saved: termios) {
    var saved = saved
    tcsetattr(terminal.input, TCSAFLUSH, &saved)
  }
}

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
