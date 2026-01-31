# TidyFlow Core

Rust-based PTY host with WebSocket server for terminal emulation.

## Features

- PTY session management (spawn shell, read/write, resize)
- WebSocket server on configurable port
- Protocol v0 with JSON messages and base64-encoded binary data
- Structured logging with tracing

## Building

```bash
cargo build --release
```

## Running

```bash
# Default port 47999
cargo run

# Custom port
TIDYFLOW_PORT=8080 cargo run

# Debug logging
RUST_LOG=debug cargo run
```

## Project Structure

```
core/
├── src/
│   ├── main.rs          # Entry point
│   ├── lib.rs           # Library exports
│   ├── pty/             # PTY management
│   │   ├── mod.rs
│   │   ├── session.rs   # PtySession struct
│   │   └── resize.rs    # Resize functionality
│   ├── server/          # WebSocket server
│   │   ├── mod.rs
│   │   ├── ws.rs        # WebSocket handler
│   │   └── protocol.rs  # Message types
│   └── util/            # Utilities
│       ├── mod.rs
│       └── log.rs       # Logging setup
└── Cargo.toml
```

## Protocol

See `design/09-m0-contracts.md` for the full protocol specification.
