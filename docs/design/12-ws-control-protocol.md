# WebSocket Control Protocol v2.0 - Binary Transport

> Frozen: 2026-02-04 (v2.0)
> Update: 2025-01-31 (v1.2)

## Overview

This document defines the WebSocket protocol for TidyFlow terminal communication. 

Starting from **v2.0**, the protocol uses **MessagePack** binary transport instead of JSON text frames to improve performance and support raw binary data without Base64 overhead.

## Connection

- **Endpoint**: `ws://127.0.0.1:47999/ws`
- **Protocol Version**: 2 (MessagePack binary transport)

## Message Format

All messages are **MessagePack-encoded binary frames**. 

- **Binary Support**: Direct binary fields (e.g., terminal I/O) are supported without Base64 encoding.
- **Client Implementation (JS)**: Use `@msgpack/msgpack` or similar. Set `ws.binaryType = 'arraybuffer'`.
- **Server Implementation (Rust)**: Use `rmp-serde` for serialization/deserialization.
- **Structure**: Every message is an object with a `type: string` field.

---

## Core Concepts (v2.0)

### Workspace Identity

A workspace is uniquely identified by the combination of `project` and `workspace` name:

```
workspace_id = project + "/" + workspace
```

### Terminal-Workspace Binding

Every terminal MUST be bound to exactly one workspace:

```
term_id → (project, workspace, cwd)
```

This binding is immutable for the lifetime of the terminal.

### Parallel Workspaces

Multiple workspaces can be active simultaneously within a single WebSocket connection:

```
Connection
├── Terminal A → Workspace "proj1/feature-x"
├── Terminal B → Workspace "proj1/feature-y"
└── Terminal C → Workspace "proj2/main"
```

---

## Terminal Data Plane (v0 Compatible Types)

Now uses raw binary `data` field via MessagePack.

### Client -> Server

```json
{"type":"input","data":"<binary>"}
{"type":"resize","cols":120,"rows":30}
{"type":"ping"}
```

### Server -> Client

```json
{"type":"hello","version":2,"session_id":"<uuid>","shell":"zsh","capabilities":["workspace_management","multi_terminal","multi_workspace","cwd_spawn"]}
{"type":"output","data":"<binary>"}
{"type":"exit","code":0}
{"type":"pong"}
```

---

## v1/v2 Messages (Control Plane) - Workspace Management

### Client -> Server

```json
{"type":"list_projects"}
{"type":"list_workspaces","project":"<name>"}
{"type":"select_workspace","project":"<name>","workspace":"<name>"}
{"type":"spawn_terminal","cwd":"<path>"}
{"type":"kill_terminal"}
```

### Server -> Client

```json
{"type":"projects","items":[{"name":"...","root":"...","workspace_count":2}]}
{"type":"workspaces","project":"...","items":[{"name":"...","root":"...","branch":"...","status":"ready"}]}
{"type":"selected_workspace","project":"...","workspace":"...","root":"...","session_id":"...","shell":"..."}
{"type":"terminal_spawned","session_id":"...","shell":"...","cwd":"..."}
{"type":"terminal_killed","session_id":"..."}
{"type":"error","code":"...","message":"..."}
```

---

## Multi-Workspace Extension (Unified in v2.0)

### Design Principles

1. **Backward Compatibility**: Old clients (v0/v1/v1.1) continue to work
2. **term_id Routing**: All data plane messages include `term_id` for multi-terminal
3. **Workspace Binding**: Each terminal is bound to exactly one workspace
4. **Parallel Workspaces**: Multiple workspaces can be active simultaneously

### Client -> Server

#### Create Terminal (v2.0)
```json
{"type":"term_create","project":"<name>","workspace":"<name>"}
```
Creates a new terminal in the specified workspace. The terminal's cwd is set to the workspace root. Returns `term_created` with workspace info.

#### List Terminals (v2.0)
```json
{"type":"term_list"}
```
Lists all terminals with their workspace bindings. Returns `term_list` with project/workspace info.

#### Close Terminal
```json
{"type":"term_close","term_id":"<id>"}
```
Closes the specified terminal. Returns `term_closed`.

#### Focus Terminal (Optional)
```json
{"type":"term_focus","term_id":"<id>"}
```
Notifies server of client focus change. Server may use for optimization.

#### Input with term_id
```json
{"type":"input","term_id":"<id>","data":"<binary>"}
```
If `term_id` is omitted, routes to default terminal (backward compatible).

#### Resize with term_id
```json
{"type":"resize","term_id":"<id>","cols":120,"rows":30}
```
If `term_id` is omitted, routes to default terminal (backward compatible).

### Server -> Client

#### Terminal Created (v2.0)
```json
{"type":"term_created","term_id":"<id>","project":"<name>","workspace":"<name>","cwd":"<path>","shell":"<shell>"}
```
Now includes `project` and `workspace` fields for workspace binding.

#### Terminal List (v2.0)
```json
{"type":"term_list","items":[{"term_id":"<id>","project":"<name>","workspace":"<name>","cwd":"<path>","status":"running|exited"}]}
```
Now includes `project` and `workspace` fields for each terminal.

#### Terminal Closed
```json
{"type":"term_closed","term_id":"<id>"}
```

#### Output with term_id
```json
{"type":"output","term_id":"<id>","data":"<binary>"}
```

#### Exit with term_id
```json
{"type":"exit","term_id":"<id>","code":0}
```

---

## Resize Strategy

**Chosen Strategy**: Per-tab resize

- Each terminal tab can have different dimensions
- Client sends `resize` with `term_id` when tab is focused/resized
- Server applies resize only to the specified terminal
- Rationale: Allows split views in future; more flexible

---

## Connection Lifecycle

1. Client connects to WebSocket
2. Server auto-spawns default terminal (HOME directory), sends `hello`
3. Client can create terminals in any workspace via `term_create`
4. Multiple workspaces can be active simultaneously
5. All terminals share the same WebSocket connection
6. On disconnect, server cleans up ALL terminals (across all workspaces)

---

## Multi-Workspace Isolation

### PTY CWD Isolation

Each terminal's PTY is spawned with `cwd` set to its workspace root:

```
Terminal A (proj1/ws-a) → PTY cwd = /path/to/proj1/.tidyflow/workspaces/ws-a
Terminal B (proj1/ws-b) → PTY cwd = /path/to/proj1/.tidyflow/workspaces/ws-b
```

### No Cross-Workspace Interference

- Terminals in different workspaces are completely isolated
- Input/output routing is strictly by `term_id`
- No shared state between terminals

---

## Error Codes

| Code | Description |
|------|-------------|
| `project_not_found` | Project does not exist |
| `workspace_not_found` | Workspace does not exist in project |
| `workspace_not_ready` | Workspace is not in Ready status |
| `invalid_path` | Path does not exist |
| `term_not_found` | Terminal ID not found |
| `spawn_failed` | Failed to spawn PTY |

---

## Implementation Notes

### Server (Rust)

- `TerminalHandle` includes: `term_id`, `project`, `workspace`, `cwd`, `pty_session`
- `TerminalManager` per connection: `HashMap<term_id, TerminalHandle>`
- `term_create` validates workspace exists and is Ready before spawning
- Cleanup on disconnect: iterate and kill all terminals (across all workspaces)

### Client (JavaScript)

- Tab data structure: `{ term_id, project, workspace, term, fitAddon, container, tabEl, cwd }`
- Tab title shows workspace name (e.g., "feature-x")
- New tab inherits current workspace by default (or shows workspace picker)
- Input routing: attach `term_id` to all input messages
- Output routing: dispatch by `term_id` to correct xterm instance

---

## Migration from v1 to v2

### Breaking Changes

1.  **Transport Format**: Changed from JSON text frames to **MessagePack binary frames**.
2.  **Binary Data Encoding**:
    *   Terminal I/O: `data_b64: string (base64)` -> `data: binary (Vec<u8>)`
    *   File API (if applicable): `content_b64: string (base64)` -> `content: binary (Vec<u8>)`
3.  **WebSocket Configuration**: Clients must set `binaryType = 'arraybuffer'`.

### New Fields

- `hello` message now returns `version: 2`.

---

## Migration from v1.1 to v1.2

### Breaking Changes

None. v1.2 is fully backward compatible with v1.1.

### New Fields

- `term_created` now includes `project` and `workspace` fields
- `term_list` items now include `project` and `workspace` fields

### Behavior Changes

- `select_workspace` no longer closes existing terminals (optional, for parallel support)
- Multiple workspaces can be active simultaneously

---

## Related Documents

- [M1 Implementation](../docs/M1_IMPLEMENTATION.md)
- [Architecture](./02-architecture.md)
- [Terminal Design](./04-terminal-design.md)
