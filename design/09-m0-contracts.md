# M0 Interface Contracts

## Core Service

### Startup
- Binary: `core/target/debug/tidyflow-core` (or release)
- Port: Default 47999, configurable via `TIDYFLOW_PORT` env var
- Logging: Controlled via `RUST_LOG` env var (default: info)

### WebSocket Endpoint
- URL: `ws://127.0.0.1:{port}/ws`
- Single session per connection (MVP)

## Protocol v0

### Server → Client Messages

#### hello (sent immediately on connect)
```json
{"type":"hello","version":0,"session_id":"uuid","shell":"zsh|bash"}
```

#### output (PTY output, base64 encoded)
```json
{"type":"output","data_b64":"base64-encoded-bytes"}
```

#### exit (shell exited)
```json
{"type":"exit","code":0}
```

#### pong (response to ping)
```json
{"type":"pong"}
```

### Client → Server Messages

#### input (send bytes to PTY)
```json
{"type":"input","data_b64":"base64-encoded-bytes"}
```

#### resize (change terminal size)
```json
{"type":"resize","cols":120,"rows":30}
```

#### ping (keepalive)
```json
{"type":"ping"}
```

## Future Extensions (Reserved)

- Multi-session: Add session management endpoints
- Multi-workspace: Add workspace context to messages
- Authentication: Add auth handshake before hello
- Binary frames: Optional binary WebSocket frames for efficiency
