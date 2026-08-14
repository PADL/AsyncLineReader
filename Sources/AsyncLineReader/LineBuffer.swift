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

/// The line being edited, as characters and a cursor position. Purely a value: it knows nothing
/// of terminals, so it can be reasoned about (and tested) on its own.
struct LineBuffer: Equatable {
  private(set) var characters: [Character] = []
  private(set) var cursor: Int = 0

  var text: String {
    String(characters)
  }

  var isEmpty: Bool {
    characters.isEmpty
  }

  var count: Int {
    characters.count
  }

  /// The text before the cursor, which is what a completion looks at.
  var textBeforeCursor: String {
    String(characters[0..<cursor])
  }

  init() {}

  init(text: String, cursor: Int? = nil) {
    characters = Array(text)
    self.cursor = cursor.map { $0.clamped(to: 0...characters.count) } ?? characters.count
  }

  mutating func insert(_ character: Character) {
    characters.insert(character, at: cursor)
    cursor += 1
  }

  mutating func insert(contentsOf text: String) {
    for character in text {
      insert(character)
    }
  }

  mutating func replace(with text: String, cursor: Int? = nil) {
    self = LineBuffer(text: text, cursor: cursor)
  }

  @discardableResult
  mutating func deleteBackward() -> Bool {
    guard cursor > 0 else { return false }
    characters.remove(at: cursor - 1)
    cursor -= 1
    return true
  }

  @discardableResult
  mutating func deleteForward() -> Bool {
    guard cursor < characters.count else { return false }
    characters.remove(at: cursor)
    return true
  }

  @discardableResult
  mutating func deleteWordBackward() -> Bool {
    let start = startOfPreviousWord
    guard start < cursor else { return false }
    characters.removeSubrange(start..<cursor)
    cursor = start
    return true
  }

  @discardableResult
  mutating func deleteToEnd() -> Bool {
    guard cursor < characters.count else { return false }
    characters.removeSubrange(cursor...)
    return true
  }

  @discardableResult
  mutating func deleteToStart() -> Bool {
    guard cursor > 0 else { return false }
    characters.removeSubrange(0..<cursor)
    cursor = 0
    return true
  }

  mutating func moveLeft() {
    cursor = max(0, cursor - 1)
  }

  mutating func moveRight() {
    cursor = min(characters.count, cursor + 1)
  }

  mutating func moveToStart() {
    cursor = 0
  }

  mutating func moveToEnd() {
    cursor = characters.count
  }

  mutating func moveWordLeft() {
    cursor = startOfPreviousWord
  }

  mutating func moveWordRight() {
    cursor = endOfNextWord
  }

  mutating func transpose() {
    guard characters.count >= 2, cursor > 0 else { return }
    let index = cursor == characters.count ? cursor - 1 : cursor
    characters.swapAt(index - 1, index)
    cursor = min(characters.count, index + 1)
  }

  private var startOfPreviousWord: Int {
    var index = cursor
    while index > 0, characters[index - 1].isWordSeparator {
      index -= 1
    }
    while index > 0, !characters[index - 1].isWordSeparator {
      index -= 1
    }
    return index
  }

  private var endOfNextWord: Int {
    var index = cursor
    while index < characters.count, characters[index].isWordSeparator {
      index += 1
    }
    while index < characters.count, !characters[index].isWordSeparator {
      index += 1
    }
    return index
  }
}

extension Character {
  var isWordSeparator: Bool {
    isWhitespace || (isPunctuation && self != "_") || isSymbol
  }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
