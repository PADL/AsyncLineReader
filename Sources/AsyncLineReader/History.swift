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

/// The lines entered so far, and where the user is whilst walking back through them.
///
/// Whilst navigating, the line the user had partly typed is kept at the end, so that coming back
/// down from the history restores it.
struct History: Equatable {
  private(set) var entries: [String] = []
  private var index: Int?
  private var pending: String?

  var maximumCount: Int = 1000

  var isNavigating: Bool {
    index != nil
  }

  mutating func append(_ line: String) {
    let line = line.trimmingWhitespace()
    guard !line.isEmpty, entries.last != line else { return }
    entries.append(line)
    if entries.count > maximumCount {
      entries.removeFirst(entries.count - maximumCount)
    }
  }

  mutating func endNavigation() {
    index = nil
    pending = nil
  }

  /// The previous entry, or nil if there is none. `current` is remembered so that it can be
  /// restored by walking forwards again.
  mutating func previous(current: String) -> String? {
    guard !entries.isEmpty else { return nil }

    let previousIndex: Int
    if let index {
      guard index > 0 else { return nil }
      previousIndex = index - 1
    } else {
      pending = current
      previousIndex = entries.count - 1
    }

    index = previousIndex
    return entries[previousIndex]
  }

  /// The next entry, or the partly typed line once the end is reached.
  mutating func next() -> String? {
    guard let index else { return nil }

    if index + 1 < entries.count {
      self.index = index + 1
      return entries[index + 1]
    }

    let pending = pending ?? ""
    endNavigation()
    return pending
  }

  /// The most recent entry starting with `prefix`, for searching backwards.
  func mostRecent(startingWith prefix: String) -> String? {
    guard !prefix.isEmpty else { return entries.last }
    return entries.last { $0.hasPrefix(prefix) && $0 != prefix }
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
