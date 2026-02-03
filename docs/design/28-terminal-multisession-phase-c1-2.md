# Phase C1-2: Multi Terminal Tab → Multi Session Mapping

## Overview

This phase implements independent PTY sessions for each Terminal Tab, enabling multiple concurrent terminal sessions within a workspace without output mixing.

## Architecture

### Session Management

```
Native (AppState)                    Web (main.js)                     Core
     │                                    │                              │
     │  terminal_spawn(tabId)             │                              │
     ├───────────────────────────────────>│  term_create                 │
     │                                    ├─────────────────────────────>│
     │                                    │                              │
     │                                    │  term_created(session_id)    │
     │  terminal_ready(tabId,sessionId)   │<─────────────────────────────┤
     │<───────────────────────────────────┤                              │
     │                                    │                              │
     │  terminal_attach(tabId,sessionId)  │                              │
     ├───────────────────────────────────>│  (switch active session)     │
     │                                    │                              │
     │  terminal_kill(tabId,sessionId)    │  term_kill                   │
     ├───────────────────────────────────>├─────────────────────────────>│
```

### Data Structures

#### Native (AppState)
```swift
// Per-tab session mapping
var terminalSessionByTabId: [UUID: String] = [:]

// Stale sessions (disconnected but tab exists)
var staleTerminalTabs: Set<UUID> = []

// TabModel extension
struct TabModel {
    var terminalSessionId: String?  // Only for terminal tabs
}
```

#### Web (main.js)
```javascript
// Session buffer management
let terminalSessions = new Map();
// sessionId -> { buffer: string[], tabId: string, project: string, workspace: string }

let activeSessionId = null;
let pendingTerminalSpawn = null;  // { tabId, project, workspace }
const MAX_BUFFER_LINES = 2000;
```

## Protocol

### Native → Web

| Event | Payload | Description |
|-------|---------|-------------|
| `terminal_spawn` | `{ project, workspace, tab_id }` | Create new PTY session for tab |
| `terminal_attach` | `{ tab_id, session_id }` | Switch to existing session |
| `terminal_kill` | `{ tab_id, session_id }` | Terminate session |

### Web → Native

| Event | Payload | Description |
|-------|---------|-------------|
| `terminal_ready` | `{ tab_id, session_id, project, workspace }` | Session created/attached |
| `terminal_closed` | `{ tab_id, session_id, code }` | Session terminated |
| `terminal_error` | `{ tab_id?, message }` | Error occurred |

## Buffer Strategy

1. **Per-session buffer**: Each session maintains a circular buffer of output lines
2. **Max size**: 2000 lines (configurable via `MAX_BUFFER_LINES`)
3. **Attach replay**: When attaching to a session, clear xterm and replay buffer
4. **Active routing**: Only write to xterm if session is active

```javascript
// Output handling
case 'output': {
    const bytes = decodeBase64(msg.data_b64);

    // Always buffer
    if (terminalSessions.has(termId)) {
        session.buffer.push(text);
        // Trim to max size
        while (session.buffer.length > MAX_BUFFER_LINES) {
            session.buffer.shift();
        }
    }

    // Only write to xterm if active
    if (termId === activeSessionId) {
        tab.term.write(bytes);
    }
}
```

## Disconnect/Reconnect Strategy

### On Disconnect
1. Native: Mark all sessions as stale (`staleTerminalTabs`)
2. Native: Clear session mappings
3. Web: Clear `terminalSessions` map
4. Tab list preserved in Native

### On Reconnect
1. When user activates a stale terminal tab:
   - Native detects `terminalNeedsRespawn(tabId)` returns true
   - Native sends `terminal_spawn` with tabId
   - New session created, tab continues working

## Workspace Scoping

- Sessions are implicitly scoped by workspace via the `project/workspace` parameters
- Different workspaces maintain independent session sets
- Switching workspaces does not affect other workspace's sessions

## Limitations

1. **No scrollback persistence**: Buffer is in-memory only, lost on page reload
2. **No WebView pooling**: Single WebView instance
3. **Buffer replay**: Full clear + replay on attach (no incremental)
4. **Session limit**: No explicit limit, but memory constrained

## Files Modified

| File | Changes |
|------|---------|
| `Models.swift` | Added `terminalSessionId` to TabModel, session mapping in AppState |
| `WebBridge.swift` | Added `terminal_spawn`, `terminal_attach`, `terminal_kill` methods |
| `TabContentHostView.swift` | Multi-session tab switching logic |
| `CenterContentView.swift` | Terminal kill callback setup |
| `main.js` | Session buffer management, Native event handlers |

## Verification

See `scripts/native-terminal-multisession-check.md` for test checklist.
