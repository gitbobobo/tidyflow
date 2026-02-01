# D3b-1: Dynamic Port Allocation Design

## Overview

This document describes the dynamic port allocation system for TidyFlow's Core process management. Instead of using a fixed port (47999), the app now allocates an available port at runtime and handles port conflicts with automatic retry.

## Architecture

### Port Allocation Strategy

**Method: BSD Socket Bind to Port 0**

The most reliable way to get an available port is to let the OS assign one:

1. Create a TCP socket
2. Bind to port 0 on 127.0.0.1
3. Call `getsockname()` to retrieve the assigned port
4. Close the socket (port is now known to be available)
5. Pass port to Core process

This approach is superior to port scanning because:
- The OS guarantees the port was available at allocation time
- No race conditions with other processes
- Works across all port ranges

### Core Startup Flow

```
App Launch
    │
    ▼
PortAllocator.findAvailablePort()
    │
    ▼
CoreProcessManager.start(port)
    │
    ├─► Process.run() fails ──► Retry (up to 5 attempts)
    │
    ▼
Process running, wait 0.5s
    │
    ▼
onCoreReady(port) callback
    │
    ▼
WSClient.connect(port: port)
    │
    ▼
App ready
```

### Retry Logic

**Trigger conditions for retry:**
- Port allocation fails
- Process fails to launch
- Process exits during startup phase

**Retry parameters:**
- Maximum attempts: 5
- Delay between attempts: 200ms
- Each attempt allocates a fresh port

### State Machine

```swift
enum CoreStatus {
    case stopped
    case starting(attempt: Int, port: Int)
    case running(port: Int, pid: Int32)
    case failed(message: String)
}
```

State transitions:
- `stopped` → `starting(1, port)` on start()
- `starting(n, port)` → `starting(n+1, newPort)` on failure (if n < 5)
- `starting(n, port)` → `running(port, pid)` on success
- `starting(5, port)` → `failed(message)` on final failure
- `running` → `stopped` on stop()
- Any → `stopped` on restart()

### WebSocket Connection

WSClient now supports dynamic URL updates:

```swift
// Update URL and reconnect
wsClient.updatePort(port, reconnect: true)

// Or with full URL
wsClient.updateBaseURL(url, reconnect: true)
```

The connection is established only after Core reports ready via callback.

### Graceful Shutdown

Stop sequence:
1. Send SIGTERM to process
2. Wait up to 1 second for graceful exit
3. If still running, send SIGKILL
4. Clean up pipes and state

## Files Modified

| File | Changes |
|------|---------|
| `AppConfig.swift` | Removed fixed port, added `makeWsURL(port:)` |
| `PortAllocator.swift` | New file for port allocation |
| `CoreProcessManager.swift` | Dynamic port, retry logic, improved shutdown |
| `WSClient.swift` | Added `updateBaseURL()`, `updatePort()`, `connect(port:)` |
| `Models.swift` | Core callbacks, deferred WS connection |
| `TopToolbarView.swift` | Display port in status |

## UI Changes

### CoreStatusView

- Running: "Core: Running :49152" (shows port)
- Starting: "Core: Starting (try 2/5)" (shows attempt)
- Failed: "Core: Failed: <message>"

### Tooltip

Shows detailed info:
- Port number
- PID
- Retry attempt
- Manual run instructions on failure

## Verification

See `scripts/packaging-dynamic-port-check.md` for verification checklist.

## Limitations

1. **No crash auto-restart** - Planned for D3b-2
2. **No log file persistence** - Planned for D4
3. **Single instance only** - No multi-instance coordination
4. **Port reuse race** - Small window between allocation and Core bind

## Future Improvements (D3b-2)

- Crash detection and auto-restart
- Health check via WS ping
- Exponential backoff on repeated failures
