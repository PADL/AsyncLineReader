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

// Bracket matching behaves as it does in swift-commandlinekit; see LICENSE.md.

/// How the prompt, the line being typed, and matching brackets are coloured.
///
/// Each property is the escape sequence to introduce that text with; the reader resets the
/// terminal afterwards. `TextAttributes` builds the usual ones without having to remember them.
public struct Style: Sendable, Equatable {
  public var prompt: String
  public var input: String
  /// applied to a bracket under the cursor and to the one it matches; matching is off when empty
  public var matchingBracket: String

  public static let none = Style()

  public init(prompt: String = "", input: String = "", matchingBracket: String = "") {
    self.prompt = prompt
    self.input = input
    self.matchingBracket = matchingBracket
  }

  public static func attributes(
    prompt: TextAttributes = .none,
    input: TextAttributes = .none,
    matchingBracket: TextAttributes = .none
  ) -> Style {
    Style(
      prompt: prompt.escapeSequence,
      input: input.escapeSequence,
      matchingBracket: matchingBracket.escapeSequence
    )
  }
}

/// A colour and weight, as select graphic rendition parameters.
public struct TextAttributes: Sendable, Equatable {
  public enum Colour: Int, Sendable {
    case black = 30
    case red = 31
    case green = 32
    case yellow = 33
    case blue = 34
    case magenta = 35
    case cyan = 36
    case white = 37
    case brightBlack = 90
    case brightRed = 91
    case brightGreen = 92
    case brightYellow = 93
    case brightBlue = 94
    case brightMagenta = 95
    case brightCyan = 96
    case brightWhite = 97
  }

  public var colour: Colour?
  public var isBold: Bool
  public var isUnderlined: Bool

  public static let none = TextAttributes()

  public init(_ colour: Colour? = nil, bold: Bool = false, underlined: Bool = false) {
    self.colour = colour
    isBold = bold
    isUnderlined = underlined
  }

  public var escapeSequence: String {
    var parameters = [Int]()
    if isBold { parameters.append(1) }
    if isUnderlined { parameters.append(4) }
    if let colour { parameters.append(colour.rawValue) }
    guard !parameters.isEmpty else { return "" }
    return "\u{1B}[\(parameters.map(String.init).joined(separator: ";"))m"
  }
}

let resetAttributes = "\u{1B}[0m"

extension Character {
  var openingBracket: Character? {
    switch self {
    case ")": "("
    case "]": "["
    case "}": "{"
    default: nil
    }
  }

  var closingBracket: Character? {
    switch self {
    case "(": ")"
    case "[": "]"
    case "{": "}"
    default: nil
    }
  }
}

extension LineBuffer {
  /// The bracket just before the cursor and the one it matches, if they are both there.
  var matchingBrackets: (Int, Int)? {
    guard cursor > 0 else { return nil }

    let index = cursor - 1
    let bracket = characters[index]

    if let opening = bracket.openingBracket {
      var depth = 0
      for other in stride(from: index - 1, through: 0, by: -1) {
        if characters[other] == bracket {
          depth += 1
        } else if characters[other] == opening {
          if depth == 0 { return (other, index) }
          depth -= 1
        }
      }
    } else if let closing = bracket.closingBracket {
      var depth = 0
      for other in (index + 1)..<characters.count {
        if characters[other] == bracket {
          depth += 1
        } else if characters[other] == closing {
          if depth == 0 { return (index, other) }
          depth -= 1
        }
      }
    }

    return nil
  }
}
