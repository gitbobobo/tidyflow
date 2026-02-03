# D3b-2: Core Crash Auto-Restart

## Overview

Implements automatic restart of the Core process when it crashes unexpectedly, with protection against restart storms.

## State Machine

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
                    ▼                                         │
┌─────────┐    ┌──────────┐    ┌─────────┐    ┌────────────┐ │
│ stopped │───▶│ starting │───▶│ running │───▶│ restarting │─┘
└─────────┘    └──────────┘    └─────────┘    └────────────┘
     ▲              │               │               │
     │              │               │               │
     │              ▼               ▼               ▼
     │         ┌────────┐      ┌────────┐      ┌────────┐
     └─────────│ failed │◀─────│ failed │◀─────│ failed │
               └────────┘      └────────┘      └────────┘
                                                (limit reached)
```

### State Transitions

| From | To | Trigger |
|------|-----|---------|
| stopped | starting | start() called |
| starting | running | Process alive after 0.5s |
| starting | starting | Port conflict (retry) |
| starting | failed | Binary not found / max retries |
| running | restarting | Unexpected termination (code != 0 or signal) |
| running | stopped | stop() called |
| restarting | starting | After backoff delay |
| restarting | failed | Auto-restart limit (3) reached |
| failed | starting | Manual restart (Cmd+R) |

## Auto-Restart Strategy

### Limits
- Maximum 3 auto-restarts per app launch
- Counter resets on manual restart (Cmd+R)
- Counter does NOT reset on successful recovery

### Exponential Backoff
| Attempt | Delay |
|---------|-------|
| 1 | 200ms |
| 2 | 500ms |
| 3 | 1200ms |

### Why These Values
- Fast initial retry (200ms): Handles transient issues
- Increasing delays: Prevents CPU thrashing
- Cap at 1.2s: User doesn't wait too long
- 3 attempts: Enough for recovery, not infinite loop

## Termination Detection

### Normal Exit (no restart)
- `stop()` called (isStopping = true)
- Exit code 0 with normal termination reason

### Unexpected Exit (triggers restart)
- Exit code != 0
- Termination reason = uncaughtSignal (SIGKILL, SIGSEGV, etc.)

### During Startup (port retry, not auto-restart)
- Process dies while isStarting = true
- Handled by existing port retry logic

## UI States

### TopToolbar Display

| State | Text | Color | Icon |
|-------|------|-------|------|
| stopped | "Core: Stopped" | Gray | stop.circle |
| starting | "Core: Starting (try N/5)" | Orange | hourglass |
| running | "Core: Running :PORT" | Green | checkmark.circle |
| restarting | "Core: Restarting (N/3)" | Yellow | arrow.triangle.2.circlepath (animated) |
| failed | "Core: Failed: MSG" | Red | exclamationmark.triangle |

### Tooltip Content
- **restarting**: Shows attempt count and last error
- **failed**: Shows error message + "Cmd+R to retry" + manual instructions

## WSClient Integration

### On Crash Detection
1. CoreProcessManager detects unexpected termination
2. Calls `onCoreRestarting` callback
3. AppState disconnects WSClient
4. Status updates to `.restarting`

### On Successful Restart
1. CoreProcessManager starts new process
2. New port allocated via PortAllocator
3. Calls `onCoreReady(newPort)` callback
4. AppState creates new WSClient connection to new port

### On Restart Limit Reached
1. CoreProcessManager calls `onCoreRestartLimitReached`
2. AppState keeps WSClient disconnected
3. User must press Cmd+R to recover

## Manual Recovery (Cmd+R)

1. User presses Cmd+R or clicks restart button
2. `AppState.restartCore()` called
3. WSClient disconnected
4. `CoreProcessManager.restart(resetCounter: true)` called
5. Auto-restart counter reset to 0
6. Normal start sequence begins

## App Exit Handling

### Preventing Restart on Quit
1. `stop()` sets `isStopping = true` immediately
2. terminationHandler checks `isStopping` first
3. If true, returns without triggering auto-restart
4. `isStopping` reset to false after cleanup

## Configuration (AppConfig.swift)

```swift
static let autoRestartLimit: Int = 3
static let autoRestartBackoffs: [TimeInterval] = [0.2, 0.5, 1.2]
```

## Files Modified

| File | Changes |
|------|---------|
| AppConfig.swift | Added autoRestartLimit, autoRestartBackoffs |
| CoreProcessManager.swift | Added restarting state, auto-restart logic, isStopping flag |
| Models.swift | Updated restartCore() to reset counter, added callbacks |
| TopToolbarView.swift | Added restarting state display with animation |

## Testing Scenarios

1. **Single crash recovery**: Kill Core once → auto-restarts → recovers
2. **Multiple crash limit**: Kill Core 3 times rapidly → enters failed state
3. **Manual recovery**: After failed state, Cmd+R → restarts successfully
4. **App quit**: Quit app → Core stops, no restart triggered
5. **Port change on restart**: After restart, new port allocated
