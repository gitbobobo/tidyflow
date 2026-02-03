# Phase C2-1: Native Diff Tab Binding

## Overview

This phase implements the binding between Native Diff Tabs and the WebView diff viewer, enabling:
- Diff Tab content displayed via WebView (not placeholder)
- Git panel file click opens Diff Tab with proper routing
- Native Working/Staged mode toggle
- Diff line click opens Editor tab via Native bridge

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Native Shell                             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ TabContentHostView                                       ││
│  │  ├─ EditorContentView (kind=editor)                     ││
│  │  ├─ TerminalContentView (kind=terminal)                 ││
│  │  └─ DiffContentView (kind=diff) ← NEW                   ││
│  │       ├─ DiffToolbar (Working/Staged toggle)            ││
│  │       ├─ WebView container                              ││
│  │       └─ DiffStatusBar                                  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
                    WebBridge Protocol
                              │
┌─────────────────────────────────────────────────────────────┐
│                     WebView (main.js)                        │
│  ┌─��───────────────────────────────────────────────────────┐│
│  │ Native Event Handler                                     ││
│  │  ├─ enter_mode: "diff" → showDiffMode()                 ││
│  │  ├─ diff_open → openDiffTabFromNative()                 ││
│  │  └─ diff_set_mode → update mode & refresh               ││
│  └─────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────┐│
│  │ Diff Tab (existing implementation)                       ││
│  │  ├─ createDiffTab() - creates diff pane                 ││
│  │  ├─ renderDiffContent() - unified/split view            ││
│  │  └─ openFileAtLine() → postToNative('open_file_request')││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Bridge Protocol

### Native → Web

| Event | Payload | Description |
|-------|---------|-------------|
| `enter_mode` | `{mode: "diff"}` | Switch to diff mode UI |
| `diff_open` | `{project, workspace, path, mode}` | Open diff for file |
| `diff_set_mode` | `{mode: "working"\|"staged"}` | Change diff mode |

### Web → Native

| Event | Payload | Description |
|-------|---------|-------------|
| `open_file_request` | `{workspace, path, line?}` | Request to open file in editor |
| `diff_error` | `{message}` | Report diff error |

## Data Model Changes

### TabModel (Models.swift)

```swift
struct TabModel {
    // ... existing fields ...
    var diffMode: String?  // "working" or "staged"
}

enum DiffMode: String, Codable {
    case working
    case staged
}
```

### AppState Extensions

```swift
var isActiveTabDiff: Bool
var activeDiffPath: String?
var activeDiffMode: DiffMode
func setActiveDiffMode(_ mode: DiffMode)
func addDiffTab(workspaceKey: String, path: String, mode: DiffMode)
```

## Implementation Files

| File | Changes |
|------|---------|
| `Models.swift` | Added `diffMode` to TabModel, `DiffMode` enum, diff helpers |
| `TabContentHostView.swift` | Added `DiffContentView`, `DiffToolbar`, `DiffStatusBar` |
| `WebBridge.swift` | Added `diffOpen()`, `diffSetMode()`, `onOpenFile`, `onDiffError` |
| `CenterContentView.swift` | Added diff callbacks, updated `shouldShowWebView` |
| `main.js` | Added diff mode handling, `openDiffTabFromNative()`, native bridge |

## User Flow

1. **Open Diff Tab**
   - User clicks file in Git panel (right sidebar)
   - Native creates/activates Diff Tab with `addDiffTab()`
   - `DiffContentView.onAppear()` sends `enter_mode("diff")` + `diff_open()`
   - Web shows diff content

2. **Toggle Working/Staged**
   - User clicks segmented control in `DiffToolbar`
   - Native updates `TabModel.diffMode`
   - Native sends `diff_open()` with new mode
   - Web refreshes diff content

3. **Click Diff Line**
   - User clicks line in diff view
   - Web calls `openFileAtLine()` which detects native diff mode
   - Web sends `open_file_request` to Native
   - Native creates/activates Editor Tab via `addEditorTab()`

4. **Switch Away and Back**
   - User switches to Terminal tab
   - `DiffContentView.onDisappear()` hides WebView
   - User switches back to Diff tab
   - `DiffContentView.onAppear()` re-sends `diff_open()`

## Limitations

1. **Line number navigation**: Editor opens at file start, not specific line (future enhancement)
2. **View mode toggle**: Unified/Split handled by Web only, no Native control
3. **No native diff rendering**: All diff rendering done in WebView

## Testing Checklist

See `scripts/native-diff-binding-check.md` for verification steps.
