# AsyncLineReader

A line editor for command line programs written with Swift concurrency. It exists because the
existing Swift ports of linenoise are synchronous: `readLine()` parks a thread until the user
presses return, and the completion callback has to answer immediately. A program whose commands
are `async` — talking to a device, a database, a server — then has to bridge back with semaphores.

Here the terminal is read by a dispatch source rather than a parked thread, and everything that
waits is a suspension that can be cancelled:

* `readLine(prompt:)` is `async` and throws on Ctrl-C or end of input
* completion handlers are `async`, so a completion may query whatever it likes
* `withInterruption { }` runs a command that would otherwise never return, and cancels it when
  the user presses escape

## Using it

```swift
import AsyncLineReader

let reader = LineReader()

await reader.setCompletionHandler { line, cursor in
  // this may await: the terminal stays responsive whilst it does
  let roles = await device.actionObjectRoles(under: line)
  return roles.map { Completion($0, replacing: wordRange) }
}

while true {
  do {
    let line = try await reader.readLine(prompt: "> ")
    try await execute(line)
  } catch LineReaderError.interrupted {
    continue                    // Ctrl-C abandons the line
  } catch LineReaderError.endOfFile {
    break                       // Ctrl-D on an empty line, or a closed input
  }
}
```

A `Completion` replaces a range of the line rather than the whole of it, so a path or an argument
can be completed one component at a time:

```swift
Completion("/Mixer@1/", replacing: 3..<6)
```

Pressing tab applies as much as every candidate agrees on; pressing it again cycles through them,
and once more restores the line as it was typed.

### Interruptible commands

```swift
let finished: Void? = try await reader.withInterruption {
  for await value in device.propertyChanges {
    print(value)
  }
}
if finished == nil { print("stopped") }
```

The terminal keeps its signal handling whilst the command runs, so Ctrl-C behaves as it usually
does. Pass `cancelOn:` to interrupt on some other key.

History can be loaded from and saved to a file with `loadHistory(fromFile:)` and
`saveHistory(toFile:)`, and `setStyle(_:)` colours the prompt, the line and matching brackets.

### Editing

Arrow keys and Home/End, Ctrl-A/E/B/F for movement, Ctrl-W and Alt-B/F by word, Ctrl-K/U to kill
to either end, Ctrl-T to transpose, Ctrl-L to clear, up and down (or Ctrl-P/N) for history. A
line still being typed is preserved whilst walking through the history and restored on the way
back. If standard input is not a terminal, lines are read without any of this, so piped input
works unchanged.

## Building

```
swift build
swift test
swift run line-reader-demo   # a small REPL: completion, history, an interruptible watch
```

## Acknowledgements

Written from scratch, but its behaviour was arrived at by reading
[swift-commandlinekit](https://github.com/objecthub/swift-commandlinekit) and, behind it,
[linenoise](https://github.com/antirez/linenoise): the terminal modes, the control key bindings,
the escape sequences the editing keys arrive as, how tab cycles through candidates, and which
bracket is matched. Their copyright notice is reproduced in `LICENSE.md`, and files that follow
their lead say so.

## Not yet done

* multi line editing: a line longer than the terminal scrolls horizontally instead of wrapping
* reverse incremental search (Ctrl-R)
* hints, i.e. the greyed out suggestion linenoise shows to the right of the cursor
* East Asian wide characters and combining marks are counted as one column each
