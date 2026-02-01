# Design 27: Native Terminal Binding (Phase C1-1)

## Overview

Phase C1-1 implements the binding of a single Terminal Tab to the WebView (xterm.js), replacing the placeholder view with a functional terminal that can interact with the Core PTY.

## Scope

**In Scope:**
- Single terminal session binding per workspace
- Mode switching between editor and terminal in WebView
- Terminal tab shows WebView with xterm.js
- Terminal I/O through existing WebSocket connection
- Error state display when Core disconnects

**Out of Scope (Future Phases):**
- Multiple terminal sessions per workspace (C1-2)
- Terminal session isolation per tab
- Diff tab WebView binding (C2)

## Architecture

### Communication Flow

```
Native Tab System                WebBridge                    Web (main.js)
      |                              |                              |
      |-- terminal tab active ------>|                              |
      |                              |-- enter_mode(terminal) ----->|
      |                              |-- terminal_ensure ---------->|
      |                              |                              |
      |                              |                    [spawn/reuse terminal]
      |                              |                              |
      |                              |<-- terminal_ready -----------|
      |<-- onTerminalReady ----------|                              |
      |                              |                              |
      |                              |<-- terminal_error -----------|
      |<-- onTerminalError ----------|                              |
```

### Bridge Protocol Extensions

**Native -> Web:**
| Message | Payload | Description |
|---------|---------|-------------|
| `enter_mode` | `{mode: "editor"\|"terminal"}` | Switch Web UI mode |
| `terminal_ensure` | `{project, workspace}` | Ensure terminal exists |

**Web -> Native:**
| Message | Payload | Description |
|---------|---------|-------------|
| `terminal_ready` | `{session_id, project, workspace}` | Terminal is ready |
| `terminal_error` | `{message}` | Terminal error occurred |
| `terminal_connected` | `{}` | WebSocket reconnected |

### State Management

**AppState (Models.swift):**
```swift
enum TerminalState: Equatable {
    case idle
    case connecting
    case ready(sessionId: String)
    case error(message: String)
}

@Published var terminalState: TerminalState = .idle
@Published var terminalSessionId: String?
```

### View Hierarchy

```
CenterContentView
├── WebViewContainer (shared, opacity controlled)
└── VStack
    ├── TabStripView
    └── TabContentHostView
        ├── TerminalContentView (when .terminal)
        │   ├── ZStack (loading/error/transparent)
        │   └── TerminalStatusBar
        ├── EditorContentView (when .editor)
        └── DiffPlaceholderView (when .diff)
```

## Implementation Details

### Web Mode Switching (main.js)

When `enter_mode(terminal)` is received:
1. Hide left sidebar and right panel
2. Hide non-terminal tabs
3. Show and activate first terminal tab
4. Fit and focus xterm instance

When `enter_mode(editor)` is received:
1. Show sidebars
2. Show all tabs
3. Restore previous active tab

### Terminal Ensure Logic

When `terminal_ensure` is received:
1. Check WebSocket connection (reconnect if needed)
2. Check if terminal exists for workspace
3. If exists: notify `terminal_ready`
4. If not: call `selectWorkspace` or `createTerminal`

### Error Handling

- WebSocket disconnect: Show error overlay with reconnect button
- Terminal spawn failure: Display error in status bar
- Connection restored: Clear error state automatically

## Limitations

1. **Single Session**: All terminal tabs in a workspace share one session
2. **No Tab Isolation**: Switching between terminal tabs doesn't switch sessions
3. **WebView Singleton**: Same WebView instance for editor and terminal

## Files Modified

| File | Changes |
|------|---------|
| `app/TidyFlow/Web/main.js` | Mode switching, terminal ensure, native bridge handlers |
| `app/TidyFlow/WebView/WebBridge.swift` | Terminal methods and callbacks |
| `app/TidyFlow/Views/Models.swift` | TerminalState enum, terminal state properties |
| `app/TidyFlow/Views/TabContentHostView.swift` | TerminalContentView, TerminalStatusBar |
| `app/TidyFlow/Views/CenterContentView.swift` | WebView visibility for terminal, bridge callbacks |

## Testing

See `scripts/native-terminal-binding-check.md` for verification steps.

## Future Work

- **C1-2**: Multiple terminal sessions with tab-session mapping
- **C2**: Diff tab WebView binding
- **C3**: Terminal pooling and lifecycle management
