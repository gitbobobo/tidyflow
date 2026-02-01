# D3b-2 Crash Restart Verification Checklist

## Prerequisites
- [ ] App builds without errors
- [ ] Core binary exists in bundle (or dev mode with cargo)

## Test Cases

### 1. Single Crash Recovery
- [ ] Start app, verify "Running :PORT" status
- [ ] Kill Core: `pkill -9 tidyflow-core` or Activity Monitor
- [ ] UI shows "Restarting (1/3)" with yellow icon
- [ ] After ~200ms, Core restarts
- [ ] UI shows "Running :PORT" (port may differ)
- [ ] Terminal/Git/Cmd+P work again

### 2. Multiple Crash - Limit Reached
- [ ] Kill Core 3 times in quick succession
- [ ] After 3rd kill, UI shows "Failed: Core crashed repeatedly"
- [ ] No more auto-restart attempts
- [ ] Tooltip shows "Cmd+R to retry"

### 3. Manual Recovery (Cmd+R)
- [ ] From failed state, press Cmd+R
- [ ] Core restarts successfully
- [ ] Counter is reset (can crash 3 more times)

### 4. App Quit - No Restart
- [ ] With Core running, quit app (Cmd+Q)
- [ ] Core process terminates
- [ ] No restart attempts in Console logs
- [ ] App exits cleanly

### 5. Port Reallocation
- [ ] Note current port from status
- [ ] Kill Core
- [ ] After restart, check port (may be same or different)
- [ ] WSClient connects to new port

### 6. WSClient State
- [ ] During restart, connection shows "Disconnected"
- [ ] After restart, connection shows "Connected"
- [ ] No stale WebSocket errors in Console

## How to Kill Core

```bash
# Method 1: pkill
pkill -9 tidyflow-core

# Method 2: Find PID and kill
ps aux | grep tidyflow-core
kill -9 <PID>

# Method 3: Activity Monitor
# Search "tidyflow-core" → Force Quit
```

## Expected Console Output

```
[CoreProcessManager] Unexpected termination: code=9, reason=1
[CoreProcessManager] Auto-restart attempt 1/3
[CoreProcessManager] Waiting 0.2s before restart...
[AppState] Core restarting (attempt 1/3)
[CoreProcessManager] Attempt 1: trying port 8081
[CoreProcessManager] Process started with PID: 12345 on port 8081
[AppState] Core ready on port 8081, connecting WebSocket
```
