# TidyFlow Core

Rust-based PTY host with WebSocket server and Workspace Engine.

## Features

- PTY session management (spawn shell, read/write, resize)
- WebSocket server on configurable port
- **Workspace Engine v1**: Project and workspace management using git worktree
- Protocol v2 with MessagePack binary messages
- Structured logging with tracing

## Building

```bash
cargo build --release
```

## Running

### WebSocket Server (Default)

```bash
# Default port 47999
cargo run

# Custom port
TIDYFLOW_PORT=8080 cargo run

# Or explicitly
cargo run -- serve --port 8080

# Debug logging
RUST_LOG=debug cargo run
```

### Workspace Engine CLI

#### Import a Project

```bash
# From local path
cargo run -- import --name my-project --path /path/to/repo

# From git URL
cargo run -- import --name my-project --git https://github.com/user/repo.git --branch main
```

#### Create a Workspace

```bash
# Create workspace with setup
cargo run -- ws create --project my-project --workspace feature-1

# Create from specific branch
cargo run -- ws create --project my-project --workspace hotfix --from-branch release/1.0

# Skip setup
cargo run -- ws create --project my-project --workspace quick --no-setup
```

#### List Projects and Workspaces

```bash
cargo run -- list projects
cargo run -- list workspaces --project my-project
```

#### Show Workspace Details

```bash
# Returns workspace root path to stdout
cargo run -- ws show --project my-project --workspace feature-1
```

#### Run Setup

```bash
cargo run -- ws setup --project my-project --workspace feature-1
```

#### Remove Workspace

```bash
cargo run -- ws remove --project my-project --workspace feature-1
```

## Project Structure

```
core/
├── src/
│   ├── main.rs          # Entry point with CLI
│   ├── lib.rs           # Library exports
│   ├── pty/             # PTY management
│   │   ├── mod.rs
│   │   ├── session.rs   # PtySession struct
│   │   └── resize.rs    # Resize functionality
│   ├── server/          # WebSocket server
│   │   ├── mod.rs
│   │   ├── ws.rs        # WebSocket handler
│   │   └── protocol.rs  # Message types
│   ├── workspace/       # Workspace Engine v1
│   │   ├── mod.rs
│   │   ├── project.rs   # Project import/management
│   │   ├── workspace.rs # Workspace creation (git worktree)
│   │   ├── config.rs    # .tidyflow.toml parsing
│   │   ├── setup.rs     # Setup step execution
│   │   └── state.rs     # State persistence
│   └── util/            # Utilities
│       ├── mod.rs
│       └── log.rs       # Logging setup
└── Cargo.toml
```

## Configuration

Projects can include a `.tidyflow.toml` file for setup configuration:

```toml
[project]
name = "my-project"
default_branch = "main"

[setup]
timeout = 300
shell = "/bin/zsh"

[[setup.steps]]
name = "Install dependencies"
run = "npm install"
condition = "file_exists:package.json"

[[setup.steps]]
name = "Build"
run = "npm run build"
continue_on_error = true

[env]
inherit = true

[env.vars]
NODE_ENV = "development"
```

See `design/05-project-config-schema.md` for the full schema.

## State Persistence

State is stored at `~/.tidyflow/state.json`.

## Protocol

See `../docs/PROTOCOL.md` for the WebSocket protocol specification.
