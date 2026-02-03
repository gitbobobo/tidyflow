# Phase B-3a: Native WS Client & Quick Open File Index

## Overview

This phase implements a minimal native WebSocket client to connect the macOS app to the Rust Core, enabling Quick Open (Cmd+P) to fetch real file indices instead of using mock data.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     TidyFlow macOS App                       │
├─────────────────────────────────────────────────────────────┤
│  AppState                                                    │
│  ├── wsClient: WSClient                                      │
│  ├── connectionState: ConnectionState                        │
│  ├── fileIndexCache: [String: FileIndexCache]               │
│  └── selectedProjectName: String                            │
├─────────────────────────────────────────────────────────────┤
│  WSClient (Networking/)                                      │
│  ├── connect() / disconnect() / reconnect()                 │
│  ├── sendJSON() / requestFileIndex()                        │
│  └── Message handlers (onFileIndexResult, onError, etc.)    │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ WebSocket (ws://127.0.0.1:47999/ws)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                       Rust Core                              │
│  ├── file_index request                                      │
│  └── file_index_result response                             │
└─────────────────────────────────────────────────────────────┘
```

## WSClient Scope

### Responsibilities
- Establish WebSocket connection to Core at `ws://127.0.0.1:47999/ws`
- Send JSON messages (file_index requests)
- Receive and parse incoming messages
- Dispatch to appropriate handlers based on message type
- Track connection state

### Not In Scope (This Phase)
- Automatic reconnection (manual via Cmd+R)
- Message queuing
- Multiple simultaneous connections
- Authentication

## Message Protocol

### Request: file_index
```json
{
  "type": "file_index",
  "project": "default",
  "workspace": "workspace-key"
}
```

### Response: file_index_result
```json
{
  "type": "file_index_result",
  "project": "default",
  "workspace": "workspace-key",
  "items": ["src/main.rs", "Cargo.toml", ...],
  "truncated": false
}
```

### Response: error
```json
{
  "type": "error",
  "message": "Error description"
}
```

## File Index Cache Strategy

### Data Structure
```swift
struct FileIndexCache {
    var items: [String]       // File paths
    var truncated: Bool       // Whether list was truncated
    var updatedAt: Date       // Last update timestamp
    var isLoading: Bool       // Currently fetching
    var error: String?        // Last error message
}
```

### Cache Key
- Workspace key (e.g., "default", "project-alpha")

### Expiration
- Cache expires after 10 minutes
- Expired cache triggers auto-refresh on Quick Open

### Refresh Triggers
1. Quick Open opened with expired/empty cache
2. Manual "Refresh File Index" command
3. Reconnect (Cmd+R)

## Error Handling

| Scenario | UI Behavior |
|----------|-------------|
| Not connected | Show "Disconnected from Core" with icon |
| No workspace selected | Show "Select a workspace first" |
| Loading in progress | Show spinner + "Loading file index..." |
| Request error | Show error message with warning icon |
| Truncated results | Show info banner at bottom of list |

## Commands Added

| Command | Scope | Key Hint | Action |
|---------|-------|----------|--------|
| Refresh File Index | workspace | - | Re-fetch file index for current workspace |

## Files Modified/Created

### New Files
- `app/TidyFlow/Networking/WSClient.swift` - WebSocket client
- `app/TidyFlow/Networking/ProtocolModels.swift` - Message models

### Modified Files
- `app/TidyFlow/Views/Models.swift` - Added fileIndexCache, wsClient, fetch methods
- `app/TidyFlow/Views/CommandPaletteView.swift` - Use cache, show states

## Limitations

1. No automatic reconnection - use Cmd+R to reconnect manually
2. Single project name hardcoded as "default"
3. No WebView tab content binding (Phase B-3b)
4. No real editor - only placeholder tabs

## Next Steps

- **Phase B-3b**: Bind Editor Tab content to WebView
- **Phase C**: Native right panel tools (Explorer, Search, Git)
