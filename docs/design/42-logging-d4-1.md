# D4-1: Core Process Logging

## Overview
Minimal log persistence for tidyflow-core stdout/stderr with rotation and size limits.

## Log Location
- Directory: `~/Library/Logs/TidyFlow/`
- Main file: `core.log`
- Rotated files: `core.1.log`, `core.2.log`, `core.3.log`, `core.4.log`

## Rotation Strategy
- **Trigger**: When `core.log` exceeds 1 MB (1,000,000 bytes)
- **Max files**: 5 (core.log + 4 rotated)
- **Rotation order**:
  1. Delete `core.4.log` if exists
  2. Rename `core.3.log` → `core.4.log`
  3. Rename `core.2.log` → `core.3.log`
  4. Rename `core.1.log` → `core.2.log`
  5. Rename `core.log` → `core.1.log`
  6. Create new empty `core.log`

## Implementation

### LogWriter.swift
- Singleton pattern (`LogWriter.shared`)
- Serial DispatchQueue for thread safety
- Methods: `initialize()`, `append(Data)`, `append(String)`, `close()`
- Auto-creates directory on first write
- Writes startup/shutdown markers with timestamps

### CoreProcessManager Integration
- Calls `LogWriter.shared.initialize()` on `start()`
- Pipes stdout/stderr data to `LogWriter.shared.append(data)`
- Calls `LogWriter.shared.close()` in `cleanup()`
- Maintains existing in-memory buffer for UI

### AppConfig Constants
- `logPathDisplay`: Human-readable path for UI display

## Privacy Boundary
- Only logs what Core process outputs to stdout/stderr
- No additional user data captured
- No structured logging or JSON formatting
- No log upload or external transmission

## Not Included (Future Work)
- UI log viewer (D4-2 Debug Panel)
- Crash reports
- Structured logging
- Log upload/analytics
