# Packaging Logging Check (D4-1)

## Pre-flight
- [ ] Build succeeds in Xcode (Cmd+B)
- [ ] No compiler warnings for LogWriter.swift

## Basic Logging
- [ ] Launch app, wait for Core to start
- [ ] Verify `~/Library/Logs/TidyFlow/` directory exists
- [ ] Verify `core.log` file exists and contains startup marker
- [ ] Perform some actions (open folder, git operations)
- [ ] Verify `core.log` grows with Core output

## Log Rotation
- [ ] Temporarily reduce `maxBytes` to 10000 in LogWriter.swift
- [ ] Generate log output until rotation triggers
- [ ] Verify `core.1.log` appears after rotation
- [ ] Verify `core.log` resets to small size
- [ ] Restore `maxBytes` to 1_000_000

## Crash Restart
- [ ] With app running, execute: `pkill -9 tidyflow-core`
- [ ] Verify Core auto-restarts
- [ ] Verify logging continues to `core.log`

## Clean Shutdown
- [ ] Quit app normally (Cmd+Q)
- [ ] Verify shutdown marker in `core.log`
- [ ] Verify no new writes after quit
