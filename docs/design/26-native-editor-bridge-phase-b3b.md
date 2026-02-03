# Phase B-3b: Native Editor Bridge

## Overview

This phase implements bidirectional communication between Native (Swift) and Web (JavaScript) for editor tab content binding. When a user opens a file via Cmd+P (Quick Open), the Native tab system creates an editor tab, and the WebView displays the actual file content.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Native (Swift)                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │  AppState   │◄──►│  WebBridge  │◄──►│ WebViewContainer│ │
│  │ (editorWeb  │    │ (send/recv) │    │   (WKWebView)   │ │
│  │  Ready,     │    └─────────────┘    └─────────────────┘ │
│  │  status)    │           │                    │          │
│  └─────────────┘           │                    │          │
└────────────────────────────┼────────────────────┼──────────┘
                             │ evaluateJavaScript │
                             │ WKScriptMessage    │
                             ▼                    ▼
┌─────────────────────────────────────────────────────────────┐
│                      Web (JavaScript)                       │
│  ┌─────────────────┐    ┌─────────────────────────────────┐│
│  │ tidyflowNative  │◄──►│         main.js                 ││
│  │ (bridge object) │    │ (handleNativeEvent, postToNative)│
│  └─────────────────┘    └─────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Bridge Protocol

### Native → Web Messages

Sent via `webView.evaluateJavaScript("window.tidyflowNative.receive(type, payload)")`

| Message Type | Payload | Description |
|--------------|---------|-------------|
| `open_file` | `{project, workspace, path}` | Open file in editor |
| `save_file` | `{project, workspace, path}` | Save current editor content |

### Web → Native Messages

Sent via `window.webkit.messageHandlers.tidyflowBridge.postMessage({type, ...payload})`

| Message Type | Payload | Description |
|--------------|---------|-------------|
| `ready` | `{capabilities: string[]}` | Web is ready to receive events |
| `saved` | `{path}` | File saved successfully |
| `save_error` | `{path, message}` | Save failed with error |

## State Machine

```
                    ┌──────────────┐
                    │   Initial    │
                    └──────┬───────┘
                           │ WebView loads
                           ▼
                    ┌──────────────┐
                    │   Loading    │
                    └──────┬───────┘
                           │ Web sends 'ready'
                           ▼
                    ┌──────────────┐
        ┌──────────►│    Ready     │◄──────────┐
        │           └──────┬───────┘           │
        │                  │ Native sends      │
        │                  │ 'open_file'       │
        │                  ▼                   │
        │           ┌──────────────┐           │
        │           │   Opening    │           │
        │           └──────┬───────┘           │
        │                  │ file_read_result  │
        │                  ▼                   │
        │           ┌──────────────┐           │
        │           │   Editing    │───────────┤
        │           └──────┬───────┘           │
        │                  │ Native sends      │
        │                  │ 'save_file'       │
        │                  ▼                   │
        │           ┌──────────────┐           │
        │           │   Saving     │           │
        │           └──────┬───────┘           │
        │                  │ 'saved' or        │
        │                  │ 'save_error'      │
        └──────────────────┴───────────────────┘
```

## Implementation Details

### WebBridge.swift

- Implements `WKScriptMessageHandler` for receiving Web messages
- Provides `send(type:payload:)` for sending to Web
- Queues events if Web not ready, flushes on ready
- Convenience methods: `openFile()`, `saveFile()`

### WebViewContainer.swift

- Configures `WKWebViewConfiguration` with:
  - User script injection (bridge script at document start)
  - Message handler registration (`tidyflowBridge`)
- Loads `index.html` from bundle

### AppState (Models.swift)

New properties:
- `editorWebReady: Bool` - Web bridge ready state
- `lastEditorPath: String?` - Currently open file path
- `editorStatus: String` - Status bar text
- `editorStatusIsError: Bool` - Error state flag

New methods:
- `getActiveTab()` - Get active tab model
- `isActiveTabEditor` - Check if editor tab active
- `activeEditorPath` - Get editor file path
- `saveActiveEditorFile()` - Trigger save via notification
- `handleEditorSaved()` / `handleEditorSaveError()` - Handle results

### main.js

New functions:
- `handleNativeEvent(type, payload)` - Handle Native events
- `postToNative(type, payload)` - Send to Native
- `notifyNativeSaved(path)` - Notify save success
- `notifyNativeSaveError(path, message)` - Notify save failure
- `initNativeBridge()` - Initialize bridge on load

## Failure Handling

### Web Not Ready
- Events queued in `pendingEvents` array
- Flushed when `ready` message received
- Timeout: None (waits indefinitely)

### Save Failure
- Web sends `save_error` with message
- Native shows error in status bar
- User can retry with Cmd+S

### File Read Failure
- Handled by existing WebSocket error flow
- Editor tab shows error state

## Files Modified

| File | Changes |
|------|---------|
| `WebBridge.swift` | Complete rewrite with bidirectional communication |
| `WebViewContainer.swift` | Added bridge configuration |
| `Models.swift` | Added editor state properties and methods |
| `TabContentHostView.swift` | Added EditorContentView with WebView binding |
| `CenterContentView.swift` | Added WebView visibility management |
| `main.js` | Added native bridge handler |

## Testing Checklist

See `scripts/native-editor-bridge-check.md` for verification steps.
