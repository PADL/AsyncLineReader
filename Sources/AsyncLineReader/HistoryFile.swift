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

import Foundation

public extension LineReader {
  /// Replaces the history with the lines of `path`, oldest first. A missing file is not an error:
  /// there simply is no history yet.
  func loadHistory(fromFile path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else { return }
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    replaceHistory(with: contents.split(separator: "\n").map(String.init))
  }

  /// Writes the history to `path`, one line per entry.
  func saveHistory(toFile path: String) throws {
    let contents = historyEntries.joined(separator: "\n") + "\n"
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
  }
}
