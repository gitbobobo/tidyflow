# M1 Implementation Summary: Workspace-Terminal CWD Binding

## Completed Tasks

### 1. Protocol v1 Extension (Rust Core)
**File:** `core/src/server/protocol.rs`

Added v1 control plane messages while maintaining v0 backward compatibility:

**Client → Server:**
- `list_projects` - Get all registered projects
- `list_workspaces { project }` - Get workspaces for a project
- `select_workspace { project, workspace }` - Switch terminal to workspace directory
- `spawn_terminal { cwd }` - Spawn terminal with custom working directory
- `kill_terminal` - Kill current terminal session

**Server → Client:**
- `projects { items }` - List of projects with name, root, workspace_count
- `workspaces { project, items }` - List of workspaces with name, root, branch, status
- `selected_workspace { project, workspace, root, session_id, shell }` - Workspace selected confirmation
- `terminal_spawned { session_id, shell, cwd }` - Terminal spawned confirmation
- `terminal_killed { session_id }` - Terminal killed confirmation
- `error { code, message }` - Error response

**Hello message enhanced:**
- `version: 1` (was 0)
- `capabilities: ["workspace_management", "multi_terminal", "cwd_spawn"]`

### 2. WebSocket Handler Update (Rust Core)
**File:** `core/src/server/ws.rs`

- Integrated `AppState` for workspace queries
- Added `TerminalState` struct for managing terminal lifecycle
- Implemented all v1 message handlers
- Terminal respawn with new cwd on workspace selection
- Error handling for invalid paths and missing projects/workspaces

### 3. JavaScript Client Update (macOS App)
**File:** `app/TidyFlow/Web/main.js`

- Added v1 control plane API: `listProjects()`, `listWorkspaces()`, `selectWorkspace()`, `spawnTerminal()`, `killTerminal()`
- State management for projects, workspaces, current selection
- Swift notification for all v1 events
- Terminal clear and status display on workspace switch

### 4. SwiftUI Workspace Selector (macOS App)
**File:** `app/TidyFlow/ContentView.swift`

- Project dropdown menu with refresh option
- Workspace dropdown menu with status badges (ready/creating/failed)
- Current workspace indicator in status bar
- Auto-fetch projects on v1 protocol detection
- Swift-JS bridge for workspace selection

### 5. Verification Scripts
**Files:**
- `scripts/verify_protocol.py` - Python WebSocket test (requires `websockets` package)
- `scripts/verify_protocol.sh` - Shell-based connectivity test
- `core/tests/protocol_v1.rs` - Rust integration tests

## Protocol Compatibility

| Feature | v0 Client | v1 Client |
|---------|-----------|-----------|
| hello/input/output/resize | ✓ | ✓ |
| ping/pong | ✓ | ✓ |
| exit | ✓ | ✓ |
| list_projects | - | ✓ |
| list_workspaces | - | ✓ |
| select_workspace | - | ✓ |
| spawn_terminal | - | ✓ |
| kill_terminal | - | ✓ |

## Usage

### Start Server
```bash
./target/release/tidyflow-core serve --port 47999
```

### Import a Project
```bash
./target/release/tidyflow-core import --name myproject --path /path/to/project
```

### Create a Workspace
```bash
./target/release/tidyflow-core ws create --project myproject --workspace feature-x
```

### Test Protocol
```bash
# Start server first, then:
cargo test --test protocol_v1 -- --ignored --nocapture
```

## Key Files Modified

```
core/
├── src/
│   └── server/
│       ├── protocol.rs  # v1 message types
│       ├── ws.rs        # WebSocket handler with workspace support
│       └── mod.rs       # Re-exports
├── tests/
│   └── protocol_v1.rs   # Integration tests
└── Cargo.toml           # Added dev-dependencies

app/TidyFlow/
├── ContentView.swift    # Workspace selector UI
└── Web/
    └── main.js          # v1 control plane client

scripts/
├── verify_protocol.py   # Python test script
└── verify_protocol.sh   # Shell test script
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      macOS App                               │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │  SwiftUI View   │    │         WKWebView               │ │
│  │  - Project Menu │    │  ┌─────────────────────────────┐│ │
│  │  - Workspace    │◄──►│  │      xterm.js + main.js    ││ │
│  │    Menu         │    │  │  - Terminal rendering       ││ │
│  │  - Status Bar   │    │  │  - v1 Control Plane API     ││ │
│  └─────────────────┘    │  └─────────────────────────────┘│ │
│                         └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │ WebSocket
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Rust Core (tidyflow-core)                 │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │   WebSocket     │    │         PTY Session             │ │
│  │   Handler       │───►│  - Shell process (zsh/bash)     │ │
│  │  - v0 data      │    │  - CWD binding                  │ │
│  │  - v1 control   │    │  - Resize support               │ │
│  └─────────────────┘    └─────────────────────────────────┘ │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                    AppState                              ││
│  │  - Projects (name, root, workspaces)                    ││
│  │  - Workspaces (name, worktree_path, branch, status)     ││
│  │  - Persisted to ~/.tidyflow/state.json                  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Next Steps

1. **Build macOS App** - Open `app/TidyFlow.xcodeproj` in Xcode and build
2. **Test End-to-End** - Import a project, create workspace, verify terminal cwd
3. **Add Workspace Creation UI** - Currently requires CLI
4. **Improve PTY Reader** - Make non-blocking for better responsiveness
