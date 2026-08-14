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

// The editing model — the key bindings, cycling through completions with the tab key, and
// matching the bracket before the cursor — follows linenoise by way of swift-commandlinekit; see
// the acknowledgements in LICENSE.md.

public enum LineReaderError: Error, Sendable, Equatable {
  /// the input ended, i.e. Ctrl-D on an empty line, or a closed standard input
  case endOfFile
  /// the line was abandoned with Ctrl-C
  case interrupted
}

/// A replacement for part of the line being edited.
public struct Completion: Sendable, Equatable {
  /// the text to put in place of `range`
  public let text: String
  /// the characters of the line to replace; the whole line if nil
  public let range: Range<Int>?

  public init(_ text: String, replacing range: Range<Int>? = nil) {
    self.text = text
    self.range = range
  }
}

/// Offers completions for a line being edited. Unlike its synchronous counterparts this may await
/// whatever it needs — a database, a network service — without blocking the terminal.
public typealias CompletionHandler = @Sendable (_ line: String, _ cursor: Int) async
  -> [Completion]

/// Reads lines from a terminal, with editing, history and completion, using structured
/// concurrency throughout: nothing here parks a thread waiting for a keystroke, and everything
/// that waits can be cancelled.
public actor LineReader {
  private let terminal: Terminal
  private let stream: ByteStream
  private let decoder: KeyDecoder
  private var history = History()
  private var completionHandler: CompletionHandler?
  private var style = Style.none
  private var maximumLineLength: Int?

  /// Whether accepted lines are added to the history automatically.
  public var addsHistoryAutomatically = true

  public init(terminal: Terminal = .standard) {
    self.terminal = terminal
    stream = ByteStream(fileDescriptor: terminal.input)
    decoder = KeyDecoder(stream: stream)
  }

  public func setCompletionHandler(_ handler: CompletionHandler?) {
    completionHandler = handler
  }

  /// How the prompt, the line and matching brackets are coloured.
  public func setStyle(_ style: Style) {
    self.style = style
  }

  /// The longest line that may be typed, if it should be limited.
  public func setMaximumLineLength(_ length: Int?) {
    maximumLineLength = length
  }

  public var historyEntries: [String] {
    history.entries
  }

  public func addHistory(_ line: String) {
    history.append(line)
  }

  public func replaceHistory(with entries: [String]) {
    history.replace(with: entries)
  }

  public func setMaximumHistoryCount(_ count: Int) {
    history.maximumCount = count
  }

  /// Reads a line, returning it without its terminating newline.
  ///
  /// - Throws: `LineReaderError.endOfFile` at end of input, `LineReaderError.interrupted` if the
  ///   user pressed Ctrl-C, or `CancellationError` if the calling task was cancelled.
  public func readLine(prompt: String = "") async throws -> String {
    guard terminal.isInteractive else {
      return try await readLineWithoutEditing()
    }

    guard let saved = TerminalMode.makeRaw(terminal) else {
      return try await readLineWithoutEditing()
    }
    defer {
      terminal.emit("\r\n")
      TerminalMode.restore(terminal, to: saved)
    }

    var buffer = LineBuffer()
    var completions = CompletionState()
    history.endNavigation()
    render(prompt: prompt, buffer: buffer)

    while true {
      guard let key = await decoder.next() else { throw LineReaderError.endOfFile }

      if key != .tab { completions.reset() }

      switch key {
      case .enter:
        let line = buffer.text
        if addsHistoryAutomatically { history.append(line) }
        return line

      case .control("c"):
        throw LineReaderError.interrupted

      case .control("d"):
        guard !buffer.isEmpty else { throw LineReaderError.endOfFile }
        buffer.deleteForward()

      case .tab:
        await complete(prompt: prompt, buffer: &buffer, state: &completions)

      case let .character(character):
        if let maximumLineLength, buffer.count >= maximumLineLength {
          bell()
        } else {
          buffer.insert(character)
        }

      case .backspace:
        if !buffer.deleteBackward() { bell() }

      case .delete:
        if !buffer.deleteForward() { bell() }

      case .left, .control("b"):
        buffer.moveLeft()

      case .right, .control("f"):
        buffer.moveRight()

      case .home, .control("a"):
        buffer.moveToStart()

      case .end, .control("e"):
        buffer.moveToEnd()

      case .wordLeft:
        buffer.moveWordLeft()

      case .wordRight:
        buffer.moveWordRight()

      case .up, .control("p"):
        if let entry = history.previous(current: buffer.text) {
          buffer.replace(with: entry)
        } else {
          bell()
        }

      case .down, .control("n"):
        if let entry = history.next() {
          buffer.replace(with: entry)
        } else {
          bell()
        }

      case .control("k"):
        if !buffer.deleteToEnd() { bell() }

      case .control("u"):
        if !buffer.deleteToStart() { bell() }

      case .control("w"):
        if !buffer.deleteWordBackward() { bell() }

      case .control("t"):
        buffer.transpose()

      case .control("l"):
        terminal.emit("\u{1B}[H\u{1B}[2J")

      default:
        break
      }

      render(prompt: prompt, buffer: buffer)
    }
  }

  /// Runs `body`, cancelling it if the user presses a key that `cancelOn` accepts — by default
  /// escape. Returns nil if it was interrupted.
  ///
  /// This is for commands that would otherwise run forever, such as watching a value change. The
  /// terminal keeps its signal handling, so Ctrl-C behaves as it usually would.
  @discardableResult
  public func withInterruption<T: Sendable>(
    cancelOn shouldCancel: @escaping @Sendable (Key) -> Bool = { $0 == .escape },
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T? {
    let saved = terminal.isInteractive ? TerminalMode.makeCharacterAtATime(terminal) : nil
    defer {
      if let saved {
        TerminalMode.restore(terminal, to: saved)
      }
    }

    let work = Task { try await body() }
    let watcher = Task { [decoder] in
      while let key = await decoder.next() {
        if shouldCancel(key) {
          work.cancel()
          return
        }
      }
    }
    defer { watcher.cancel() }

    do {
      let value = try await work.value
      await stream.flush()
      return value
    } catch is CancellationError {
      await stream.flush()
      return nil
    }
  }

  private func readLineWithoutEditing() async throws -> String {
    var bytes = [UInt8]()
    while let byte = await stream.next() {
      if byte == 0x0A {
        return String(decoding: bytes, as: UTF8.self)
      }
      bytes.append(byte)
    }

    guard !bytes.isEmpty else { throw LineReaderError.endOfFile }
    return String(decoding: bytes, as: UTF8.self)
  }

  private func bell() {
    terminal.emit(Ansi.bell)
  }

  // MARK: - completion

  private struct CompletionState {
    var candidates: [Completion] = []
    var original: LineBuffer?
    var index: Int?

    var isActive: Bool {
      original != nil
    }

    mutating func reset() {
      candidates = []
      original = nil
      index = nil
    }
  }

  private func complete(
    prompt: String,
    buffer: inout LineBuffer,
    state: inout CompletionState
  ) async {
    if !state.isActive {
      guard let completionHandler else { return }
      let candidates = await completionHandler(buffer.text, buffer.cursor)
      guard !candidates.isEmpty else {
        bell()
        return
      }

      state.candidates = candidates
      state.original = buffer

      // as much of the completion as every candidate agrees on can be applied straight away
      if let shared = Self.sharedCompletion(of: candidates) {
        let completed = Self.apply(shared, to: buffer)
        if completed != buffer {
          buffer = completed
          if candidates.count == 1 { state.reset() }
          return
        }
      }
    }

    // otherwise each press of the tab key shows the next candidate, and the line as it was
    // typed after the last of them
    guard let original = state.original else { return }
    let next = state.index.map { $0 + 1 } ?? 0

    if next < state.candidates.count {
      state.index = next
      buffer = Self.apply(state.candidates[next], to: original)
    } else {
      state.index = nil
      buffer = original
      bell()
    }
  }

  static func apply(_ completion: Completion, to buffer: LineBuffer) -> LineBuffer {
    guard let range = completion.range else {
      return LineBuffer(text: completion.text)
    }

    let characters = Array(buffer.text)
    let lowerBound = min(range.lowerBound, characters.count)
    let upperBound = min(max(range.upperBound, lowerBound), characters.count)
    let prefix = String(characters[0..<lowerBound])
    let suffix = String(characters[upperBound...])
    return LineBuffer(
      text: prefix + completion.text + suffix,
      cursor: prefix.count + completion.text.count
    )
  }

  /// The longest completion all the candidates share, if they replace the same range.
  static func sharedCompletion(of candidates: [Completion]) -> Completion? {
    guard let first = candidates.first else { return nil }
    guard candidates.allSatisfy({ $0.range == first.range }) else { return nil }

    var shared = Array(first.text)
    for candidate in candidates.dropFirst() {
      let text = Array(candidate.text)
      var count = 0
      while count < shared.count, count < text.count, shared[count] == text[count] {
        count += 1
      }
      shared = Array(shared[0..<count])
      if shared.isEmpty { break }
    }

    return Completion(String(shared), replacing: first.range)
  }

  // MARK: - rendering

  private func render(prompt: String, buffer: LineBuffer) {
    let width = terminal.width
    let promptWidth = Self.displayWidth(of: prompt)
    let available = max(1, width - promptWidth - 1)

    // scroll the line horizontally so that the cursor is always on screen
    var start = 0
    var cursor = buffer.cursor
    let characters = Array(buffer.text)
    if cursor > available {
      start = cursor - available
      cursor = available
    }
    let end = min(characters.count, start + available)

    terminal.emit(
      Ansi.carriageReturn + styled(prompt, with: style.prompt) +
        styledLine(buffer, showing: start..<end) + Ansi.eraseToEndOfLine +
        Ansi.setColumn(promptWidth + cursor + 1)
    )
  }

  private func styled(_ text: String, with attributes: String) -> String {
    attributes.isEmpty ? text : attributes + text + resetAttributes
  }

  /// The visible part of the line, with the bracket under the cursor and its match picked out.
  private func styledLine(_ buffer: LineBuffer, showing range: Range<Int>) -> String {
    let characters = buffer.characters
    let brackets = style.matchingBracket.isEmpty ? nil : buffer.matchingBrackets

    guard let brackets else {
      return styled(String(characters[range]), with: style.input)
    }

    var text = ""
    var applied: String?

    for index in range {
      let wanted = index == brackets.0 || index == brackets.1
        ? style.matchingBracket
        : style.input
      if wanted != applied {
        text += resetAttributes + wanted
        applied = wanted
      }
      text.append(characters[index])
    }

    return text + resetAttributes
  }

  /// The width of a string as displayed, ignoring any escape sequences it contains so that a
  /// coloured prompt still positions the cursor correctly.
  static func displayWidth(of string: String) -> Int {
    var width = 0
    var inEscapeSequence = false

    for character in string {
      if inEscapeSequence {
        if character.isLetter { inEscapeSequence = false }
      } else if character == "\u{1B}" {
        inEscapeSequence = true
      } else {
        width += 1
      }
    }

    return width
  }
}
