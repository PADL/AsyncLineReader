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

// Which escape sequences the editing and cursor keys arrive as, and which control keys mean
// what, follow linenoise by way of swift-commandlinekit; see the acknowledgements in LICENSE.md.

/// A keystroke, as decoded from the terminal's byte stream.
public enum Key: Sendable, Equatable {
  case character(Character)
  /// a control character, given as the letter it is typed with: Ctrl-A is `control("a")`
  case control(Character)
  case enter
  case tab
  case backTab
  case backspace
  case delete
  case escape
  case up
  case down
  case left
  case right
  case home
  case end
  case wordLeft
  case wordRight
  case unknown([UInt8])
}

/// How long to wait for the remainder of an escape sequence before concluding that the user
/// pressed escape on its own. Terminals send the bytes of a sequence together, so this only has
/// to outlast the scheduling jitter.
let escapeSequenceTimeout = Duration.milliseconds(40)

/// Decodes keystrokes from a stream of bytes.
struct KeyDecoder {
  let stream: ByteStream

  /// Returns the next keystroke, or nil at end of file.
  func next() async -> Key? {
    guard let byte = await stream.next() else { return nil }

    switch byte {
    case 0x0D, 0x0A:
      return .enter
    case 0x09:
      return .tab
    case 0x7F, 0x08:
      return .backspace
    case 0x1B:
      return await decodeEscapeSequence()
    case 0x00...0x1F:
      let letter = Character(UnicodeScalar(byte + 0x60))
      return .control(letter)
    default:
      return await decodeCharacter(startingWith: byte)
    }
  }

  /// Reassembles a multi byte UTF-8 encoded character.
  private func decodeCharacter(startingWith byte: UInt8) async -> Key {
    var bytes = [byte]
    let continuations = switch byte {
    case 0xC0...0xDF: 1
    case 0xE0...0xEF: 2
    case 0xF0...0xF7: 3
    default: 0
    }

    for _ in 0..<continuations {
      guard let continuation = await stream.next(timeout: escapeSequenceTimeout),
            continuation & 0xC0 == 0x80
      else {
        return .unknown(bytes)
      }
      bytes.append(continuation)
    }

    guard let character = String(decoding: bytes, as: UTF8.self).first else {
      return .unknown(bytes)
    }
    return .character(character)
  }

  private func decodeEscapeSequence() async -> Key {
    guard let byte = await stream.next(timeout: escapeSequenceTimeout) else {
      return .escape
    }

    switch byte {
    case UInt8(ascii: "["):
      return await decodeControlSequence()
    case UInt8(ascii: "O"):
      // application cursor keys, as sent by some terminals
      guard let final = await stream.next(timeout: escapeSequenceTimeout) else {
        return .unknown([0x1B, byte])
      }
      return Self.cursorKey(final: final) ?? .unknown([0x1B, byte, final])
    case UInt8(ascii: "b"):
      return .wordLeft
    case UInt8(ascii: "f"):
      return .wordRight
    default:
      // not a sequence we know: treat the escape as its own keystroke and let the byte that
      // followed it be decoded on its own
      await stream.unread(byte)
      return .escape
    }
  }

  private func decodeControlSequence() async -> Key {
    var parameters = [UInt8]()

    while let byte = await stream.next(timeout: escapeSequenceTimeout) {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: ";"):
        parameters.append(byte)
      case UInt8(ascii: "~"):
        return Self.editingKey(parameters: parameters)
          ?? .unknown([0x1B, UInt8(ascii: "[")] + parameters + [byte])
      default:
        if let key = Self.cursorKey(final: byte, parameters: parameters) {
          return key
        }
        return .unknown([0x1B, UInt8(ascii: "[")] + parameters + [byte])
      }
    }

    return .unknown([0x1B, UInt8(ascii: "[")] + parameters)
  }

  /// CSI sequences ending in a letter: the cursor keys, with an optional modifier parameter.
  private static func cursorKey(final: UInt8, parameters: [UInt8] = []) -> Key? {
    // a modifier of 1;5 (control) or 1;3 (alt) turns the left and right cursor keys into word
    // movement, which is how most terminals send Ctrl-Left and Alt-Left
    let modified = parameters.count >= 2 && parameters.last != UInt8(ascii: "2")
      && parameters.contains(UInt8(ascii: ";"))

    switch final {
    case UInt8(ascii: "A"): return .up
    case UInt8(ascii: "B"): return .down
    case UInt8(ascii: "C"): return modified ? .wordRight : .right
    case UInt8(ascii: "D"): return modified ? .wordLeft : .left
    case UInt8(ascii: "H"): return .home
    case UInt8(ascii: "F"): return .end
    case UInt8(ascii: "Z"): return .backTab
    default: return nil
    }
  }

  /// CSI sequences ending in a tilde, which are numbered rather than named.
  private static func editingKey(parameters: [UInt8]) -> Key? {
    switch String(decoding: parameters, as: UTF8.self).split(separator: ";").first {
    case "1", "7": .home
    case "3": .delete
    case "4", "8": .end
    default: nil
    }
  }
}
