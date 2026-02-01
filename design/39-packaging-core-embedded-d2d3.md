# D2/D3: Core Embedded in App Bundle

## Overview

This document describes the minimal viable implementation for embedding tidyflow-core
into the TidyFlow.app bundle and managing its lifecycle.

## Bundle Structure

```
TidyFlow.app/
├── Contents/
│   ├── MacOS/
│   │   └── TidyFlow          # Main app executable
│   ├── Resources/
│   │   ├── Core/
│   │   │   └── tidyflow-core # Core binary (copied by build phase)
│   │   └── Web/              # Web assets
│   └── Info.plist
```

## Port Configuration

- **Fixed port**: 47999 (no dynamic port detection in MVP)
- **Single source of truth**: `AppConfig.swift`
- **Core receives port via**: CLI argument `--port 47999` AND env var `TIDYFLOW_PORT`

## Startup Sequence

1. `TidyFlowApp` creates `AppState` as `@StateObject`
2. `AppState.init()` calls `startCoreIfNeeded()`
3. `CoreProcessManager.start()`:
   - Locates binary at `Bundle.main.resourceURL/Core/tidyflow-core`
   - Spawns process with `serve --port 47999`
   - Sets status to `.starting`, then `.running` after 0.5s
4. `AppState.setupWSClient()` connects to `ws://127.0.0.1:47999/ws`

## Shutdown Sequence

1. User quits app (Cmd+Q or menu)
2. `AppDelegate.applicationWillTerminate()` called
3. `appState.stopCore()` invoked
4. `CoreProcessManager.stop()`:
   - Sends SIGTERM to process
   - Waits 2 seconds
   - Sends SIGKILL if still running

## Build Phases

### 1. Build Core (Run Script)

Runs `cargo build --release` in `../core` directory.
Skip with `SKIP_CORE_BUILD=1` for faster dev iterations.

### 2. Copy Core Binary

Copies `core/target/release/tidyflow-core` to `Contents/Resources/Core/`.
Currently manual setup required (see Xcode Configuration below).

## Xcode Configuration

### Adding Core Binary to Copy Files Phase

1. Open TidyFlow.xcodeproj
2. Select TidyFlow target → Build Phases
3. Find "Copy Core Binary" phase
4. Click + and add file:
   - Navigate to `core/target/release/tidyflow-core`
   - Or drag from Finder after building core once

### Environment Variables (Optional)

In Scheme → Run → Arguments → Environment Variables:
- `SKIP_CORE_BUILD=1` - Skip cargo build during Xcode build

## Status Display

Toolbar shows Core status:
- **Stopped** (gray) - Process not running
- **Starting** (orange) - Process spawning
- **Running** (green) - Process healthy
- **Failed** (red) - Process crashed or failed to start

Hover tooltip shows manual run instructions on failure.

## Files Changed

| File | Change |
|------|--------|
| `AppConfig.swift` | NEW - Port/URL configuration |
| `Process/CoreProcessManager.swift` | NEW - Process lifecycle |
| `TidyFlowApp.swift` | Add AppDelegate for termination |
| `ContentView.swift` | Receive AppState from environment |
| `Views/TopToolbarView.swift` | Add CoreStatusView |
| `Views/Models.swift` | Add coreProcessManager, startup logic |
| `Networking/WSClient.swift` | Use AppConfig for URL |
| `project.pbxproj` | Add files, build phases |

## Limitations (MVP)

1. **No dynamic port**: If 47999 is occupied, startup fails
2. **No auto-restart**: If core crashes, manual app restart required
3. **No log persistence**: Logs only in memory (last 50 lines)
4. **Manual binary setup**: Must add core binary to Copy Files phase manually

## Next Steps

- **D3b**: Dynamic port detection, port conflict handling
- **D4**: Log collection, crash reporting
- **D5**: DMG packaging, code signing, notarization
