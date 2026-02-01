# Packaging Dev Check (D2/D3)

## Pre-requisites
1. [ ] Core built: `cd core && cargo build --release`
2. [ ] Xcode project opened

## Xcode Setup (One-time)
3. [ ] In Build Phases → "Copy Core Binary" → Add `core/target/release/tidyflow-core`

## Verification Steps

### Core Auto-Start
4. [ ] Kill any existing core: `pkill tidyflow-core`
5. [ ] Run app from Xcode (Cmd+R)
6. [ ] Toolbar shows "Core: Starting" then "Core: Running"
7. [ ] Verify process: `ps aux | grep tidyflow-core | grep -v grep`

### WebSocket Connection
8. [ ] Status shows "Connected" (green dot)
9. [ ] Cmd+P opens file palette, shows files
10. [ ] Terminal tab works (if workspace configured)
11. [ ] Git panel shows status (if git repo)

### App Exit Cleanup
12. [ ] Quit app (Cmd+Q)
13. [ ] Verify no residual: `ps aux | grep tidyflow-core | grep -v grep` (should be empty)

### Restart Test
14. [ ] Run app again from Xcode
15. [ ] Core starts without port conflict
