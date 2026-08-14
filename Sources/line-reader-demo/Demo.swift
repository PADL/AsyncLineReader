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

import AsyncLineReader

/// A small REPL demonstrating asynchronous completion and an interruptible command.
///
///   help          list the commands
///   watch         print the time until escape is pressed
///   slow          a completion that takes a moment, to show that the terminal stays responsive
@main
struct Demo {
  static let commands = ["help", "watch", "slow", "quit"]

  static func main() async {
    let reader = LineReader()

    await reader.setCompletionHandler { line, cursor in
      let prefix = String(Array(line)[0..<cursor])
      let start = prefix.lastIndex(of: " ").map { prefix.index(after: $0) } ?? prefix.startIndex
      let word = String(prefix[start...])
      let offset = prefix.distance(from: prefix.startIndex, to: start)

      // a completion may await: the terminal keeps redrawing whilst it does
      if word.hasPrefix("s") {
        try? await Task.sleep(for: .milliseconds(250))
      }

      return commands
        .filter { $0.hasPrefix(word) }
        .map { Completion($0, replacing: offset..<cursor) }
    }

    while true {
      let line: String
      do {
        line = try await reader.readLine(prompt: "demo> ")
      } catch LineReaderError.interrupted {
        print("interrupted; type quit to exit\r")
        continue
      } catch {
        break
      }

      switch line.trimmingWhitespace() {
      case "":
        continue
      case "quit":
        return
      case "help":
        print("commands: \(commands.joined(separator: ", "))")
      case "watch":
        print("watching; press escape to stop")
        await watch(with: reader)
      default:
        print("unknown command: \(line)")
      }
    }
  }

  static func watch(with reader: LineReader) async {
    let completed: ()? = try? await reader.withInterruption {
      var count = 0
      while true {
        count += 1
        print("tick \(count)")
        try await Task.sleep(for: .seconds(1))
      }
    }

    if completed == nil {
      print("stopped")
    }
  }
}

extension String {
  func trimmingWhitespace() -> String {
    var characters = Array(self)
    while let first = characters.first, first.isWhitespace {
      characters.removeFirst()
    }
    while let last = characters.last, last.isWhitespace {
      characters.removeLast()
    }
    return String(characters)
  }
}
