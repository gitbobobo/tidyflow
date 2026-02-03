# Phase C2-1.5: Editor Line Reveal (Diff Click -> Editor Navigation)

## Overview

When clicking a diff line, the editor opens at the exact line with a 2-second highlight.

## Message Protocol

### Web -> Native (existing, unchanged)

```json
{
  "type": "open_file_request",
  "workspace": "default",
  "path": "src/main.rs",
  "line": 42
}
```

- `line`: 1-based line number (optional, null if not specified)

### Native -> Web (new)

```json
{
  "type": "editor_reveal_line",
  "path": "src/main.rs",
  "line": 42,
  "highlightMs": 2000
}
```

- `path`: File path (must match an open editor tab)
- `line`: 1-based line number to reveal
- `highlightMs`: Highlight duration in milliseconds (default: 2000)

## Line Number Convention

- All line numbers are **1-based** (first line = 1)
- Matches CodeMirror's `doc.line()` API which is also 1-based
- Matches git diff output which is 1-based

## Boundary Handling

| Scenario | Behavior |
|----------|----------|
| `line > totalLines` | Jump to last line |
| `line < 1` | Jump to first line |
| `line = null/undefined` | No line navigation |
| File not open | Log warning, no action |
| Editor not ready | Queue in `pendingEditorReveal` |

## State Management

### Native (Models.swift)

```swift
// Pending reveal when editor not ready
@Published var pendingEditorReveal: (path: String, line: Int, highlightMs: Int)?
```

- Set when `addEditorTab` is called with a line parameter
- Consumed by `EditorContentView.sendOpenFile()` after file loads
- Cleared after reveal is sent

### Web (main.js)

No additional state needed. The `editor_reveal_line` handler finds the tab and calls `scrollToLineAndHighlight()`.

## Flow Diagram

```
[Diff View] --click--> [Web: postToNative('open_file_request', {line})]
                              |
                              v
[Native: WebBridge.onOpenFile] --> [AppState.addEditorTab(line)]
                                          |
                                          v
                              [Set pendingEditorReveal if line != nil]
                                          |
                                          v
[EditorContentView.onAppear] --> [sendOpenFile()]
                                          |
                                          v
                              [Check pendingEditorReveal]
                                          |
                                          v
[WebBridge.editorRevealLine()] --> [Web: handleNativeEvent('editor_reveal_line')]
                                          |
                                          v
                              [scrollToLineAndHighlight(tab, line, ms)]
```

## Highlight Implementation

Uses CodeMirror's `Decoration.line()` with a custom CSS class:

```css
.cm-highlight-line {
  background-color: rgba(255, 255, 0, 0.3);
}
```

The highlight is applied via a `StateField` and removed after `highlightMs` using `setTimeout`.

## Files Modified

| File | Changes |
|------|---------|
| `Models.swift` | Added `pendingEditorReveal` property, updated `addEditorTab` |
| `WebBridge.swift` | Added `editorRevealLine()` method |
| `CenterContentView.swift` | Updated `onOpenFile` callback |
| `TabContentHostView.swift` | Added pending reveal handling in `sendOpenFile()` |
| `main.js` | Added `editor_reveal_line` handler, updated highlight functions |

## Testing Checklist

See `scripts/editor-line-reveal-check.md`
