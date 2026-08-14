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

import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import AsyncLineReader

/// A pipe standing in for a terminal, so that keystrokes can be fed to the decoder.
private struct Keyboard: ~Copyable {
  let readEnd: CInt
  let writeEnd: CInt

  init() {
    var descriptors = [CInt](repeating: 0, count: 2)
    _ = descriptors.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }
    readEnd = descriptors[0]
    writeEnd = descriptors[1]
  }

  func type(_ bytes: [UInt8]) {
    var bytes = bytes
    _ = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) }
  }

  func type(_ string: String) {
    type(Array(string.utf8))
  }

  func endInput() {
    close(writeEnd)
  }

  deinit {
    close(readEnd)
  }
}

struct KeyDecoderTests {
  private func keys(from bytes: [UInt8], count: Int) async -> [Key] {
    let keyboard = Keyboard()
    keyboard.type(bytes)

    let decoder = KeyDecoder(stream: ByteStream(fileDescriptor: keyboard.readEnd))
    var keys = [Key]()
    for _ in 0..<count {
      guard let key = await decoder.next() else { break }
      keys.append(key)
    }
    keyboard.endInput()
    return keys
  }

  @Test
  func decodesPrintableCharacters() async {
    #expect(await keys(from: Array("ab".utf8), count: 2) == [.character("a"), .character("b")])
  }

  @Test
  func decodesMultiByteCharacters() async {
    #expect(await keys(from: Array("é€".utf8), count: 2) == [.character("é"), .character("€")])
  }

  @Test
  func decodesControlCharacters() async {
    #expect(await keys(from: [0x01, 0x05, 0x17], count: 3) ==
      [.control("a"), .control("e"), .control("w")])
  }

  @Test
  func decodesEnterTabAndBackspace() async {
    #expect(await keys(from: [0x0D, 0x09, 0x7F], count: 3) == [.enter, .tab, .backspace])
  }

  @Test
  func decodesCursorKeys() async {
    let bytes = Array("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D".utf8)
    #expect(await keys(from: bytes, count: 4) == [.up, .down, .right, .left])
  }

  @Test
  func decodesHomeEndAndDelete() async {
    let bytes = Array("\u{1B}[H\u{1B}[F\u{1B}[3~".utf8)
    #expect(await keys(from: bytes, count: 3) == [.home, .end, .delete])
  }

  @Test
  func decodesWordMovement() async {
    let bytes = Array("\u{1B}[1;5C\u{1B}[1;5D".utf8)
    #expect(await keys(from: bytes, count: 2) == [.wordRight, .wordLeft])
  }

  /// escape on its own must not swallow the key that follows it
  @Test
  func decodesBareEscape() async {
    #expect(await keys(from: [0x1B], count: 1) == [.escape])
    #expect(await keys(from: [0x1B, UInt8(ascii: "x")], count: 2) ==
      [.escape, .character("x")])
  }
}

struct LineBufferTests {
  @Test
  func insertsAtTheCursor() {
    var buffer = LineBuffer(text: "ac", cursor: 1)
    buffer.insert("b")
    #expect(buffer.text == "abc")
    #expect(buffer.cursor == 2)
  }

  @Test
  func deletesEitherSideOfTheCursor() {
    var buffer = LineBuffer(text: "abc", cursor: 2)
    var deleted = buffer.deleteBackward()
    #expect(deleted)
    #expect(buffer.text == "ac")

    deleted = buffer.deleteForward()
    #expect(deleted)
    #expect(buffer.text == "a")

    deleted = buffer.deleteForward()
    #expect(!deleted)
  }

  @Test
  func deletesWholeWords() {
    var buffer = LineBuffer(text: "cd /some/path ")
    let deleted = buffer.deleteWordBackward()
    #expect(deleted)
    #expect(buffer.text == "cd /some/")
  }

  @Test
  func killsToEitherEnd() {
    var buffer = LineBuffer(text: "abcdef", cursor: 3)
    var deleted = buffer.deleteToEnd()
    #expect(deleted)
    #expect(buffer.text == "abc")

    buffer = LineBuffer(text: "abcdef", cursor: 3)
    deleted = buffer.deleteToStart()
    #expect(deleted)
    #expect(buffer.text == "def")
    #expect(buffer.cursor == 0)
  }

  @Test
  func movesByWord() {
    var buffer = LineBuffer(text: "one two three")
    buffer.moveWordLeft()
    #expect(buffer.cursor == 8)
    buffer.moveWordLeft()
    #expect(buffer.cursor == 4)
    buffer.moveWordRight()
    #expect(buffer.cursor == 7)
  }

  @Test
  func clampsTheCursor() {
    let buffer = LineBuffer(text: "abc", cursor: 99)
    #expect(buffer.cursor == 3)
  }
}

struct HistoryTests {
  @Test
  func ignoresBlankAndRepeatedEntries() {
    var history = History()
    history.append("one")
    history.append("one")
    history.append("   ")
    history.append("two")
    #expect(history.entries == ["one", "two"])
  }

  @Test
  func walksBackAndForwards() {
    var history = History()
    history.append("one")
    history.append("two")

    var entry = history.previous(current: "partial")
    #expect(entry == "two")
    entry = history.previous(current: "partial")
    #expect(entry == "one")
    entry = history.previous(current: "partial")
    #expect(entry == nil)

    entry = history.next()
    #expect(entry == "two")
    // coming back past the newest entry restores what had been typed
    entry = history.next()
    #expect(entry == "partial")
    #expect(!history.isNavigating)
  }

  @Test
  func discardsTheOldestEntries() {
    var history = History()
    history.maximumCount = 2
    for entry in ["one", "two", "three"] {
      history.append(entry)
    }
    #expect(history.entries == ["two", "three"])
  }
}

struct CompletionTests {
  @Test
  func replacesTheGivenRange() {
    let buffer = LineBuffer(text: "cd /foo/ba", cursor: 10)
    let completed = LineReader.apply(Completion("/foo/bar/", replacing: 3..<10), to: buffer)
    #expect(completed.text == "cd /foo/bar/")
    #expect(completed.cursor == 12)
  }

  @Test
  func sharesTheLongestCommonPrefix() {
    let shared = LineReader.sharedCompletion(of: [
      Completion("mixer1", replacing: 3..<4),
      Completion("mixer2", replacing: 3..<4),
    ])
    #expect(shared == Completion("mixer", replacing: 3..<4))
  }

  @Test
  func doesNotShareAcrossDifferentRanges() {
    let shared = LineReader.sharedCompletion(of: [
      Completion("a", replacing: 0..<1),
      Completion("a", replacing: 1..<2),
    ])
    #expect(shared == nil)
  }

  @Test
  func measuresPromptsIgnoringEscapeSequences() {
    #expect(LineReader.displayWidth(of: "\u{1B}[32;1m/foo> \u{1B}[0m") == 6)
  }
}

struct StyleTests {
  @Test
  func buildsEscapeSequences() {
    #expect(TextAttributes(.green, bold: true).escapeSequence == "\u{1B}[1;32m")
    #expect(TextAttributes.none.escapeSequence == "")
  }

  @Test
  func matchesTheBracketBeforeTheCursor() {
    // a closing bracket just typed finds its opening partner
    var buffer = LineBuffer(text: "call (a b)", cursor: 10)
    #expect(buffer.matchingBrackets.map { [$0.0, $0.1] } == [5, 9])

    // and the other way round, with the cursor just after an opening bracket
    buffer = LineBuffer(text: "call (a b)", cursor: 6)
    #expect(buffer.matchingBrackets.map { [$0.0, $0.1] } == [5, 9])
  }

  @Test
  func skipsNestedBrackets() {
    let buffer = LineBuffer(text: "((a) b)", cursor: 7)
    #expect(buffer.matchingBrackets.map { [$0.0, $0.1] } == [0, 6])
  }

  @Test
  func findsNoMatchWhenUnbalanced() {
    let buffer = LineBuffer(text: "(a b", cursor: 1)
    #expect(buffer.matchingBrackets == nil)
  }
}

struct HistoryReplacementTests {
  @Test
  func replacesTheWholeHistory() {
    var history = History()
    history.append("old")
    history.replace(with: ["one", "two"])
    #expect(history.entries == ["one", "two"])
    #expect(!history.isNavigating)
  }
}

struct ByteStreamTests {
  @Test
  func buffersBytesThatArriveBeforeTheyAreWanted() async {
    let keyboard = Keyboard()
    keyboard.type("hi")

    let stream = ByteStream(fileDescriptor: keyboard.readEnd)
    #expect(await stream.next() == UInt8(ascii: "h"))
    #expect(await stream.next() == UInt8(ascii: "i"))
    keyboard.endInput()
  }

  @Test
  func returnsNilAtEndOfFile() async {
    let keyboard = Keyboard()
    keyboard.type("x")
    keyboard.endInput()

    let stream = ByteStream(fileDescriptor: keyboard.readEnd)
    #expect(await stream.next() == UInt8(ascii: "x"))
    #expect(await stream.next() == nil)
  }

  /// a read that times out must not lose the byte that arrives after it
  @Test
  func keepsBytesThatArriveAfterATimeout() async {
    let keyboard = Keyboard()

    let stream = ByteStream(fileDescriptor: keyboard.readEnd)
    #expect(await stream.next(timeout: .milliseconds(20)) == nil)

    keyboard.type("z")
    #expect(await stream.next() == UInt8(ascii: "z"))
    keyboard.endInput()
  }

  @Test
  func unreadsALookaheadByte() async throws {
    let keyboard = Keyboard()
    keyboard.type("ab")

    let stream = ByteStream(fileDescriptor: keyboard.readEnd)
    let first = await stream.next()
    try await stream.unread(#require(first))
    #expect(await stream.next() == UInt8(ascii: "a"))
    #expect(await stream.next() == UInt8(ascii: "b"))
    keyboard.endInput()
  }
}
