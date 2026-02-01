# Design 18: File Index API for Quick Open

## Overview

This document describes the file index API that provides a complete file listing for the Quick Open (Cmd+P) feature. Unlike the Explorer-based approach which only shows expanded directories, this API returns all files in the workspace recursively.

## Protocol Messages

### Client → Server

```json
{
  "type": "file_index",
  "project": "my-project",
  "workspace": "main"
}
```

### Server → Client

```json
{
  "type": "file_index_result",
  "project": "my-project",
  "workspace": "main",
  "items": ["src/main.rs", "src/lib.rs", "README.md", ...],
  "truncated": false
}
```

## Filtering Rules

### Ignored Directories (Default)

The following directories are excluded from indexing:

| Directory | Reason |
|-----------|--------|
| `.git` | Version control |
| `.build` | Swift build artifacts |
| `.swiftpm` | Swift package manager |
| `.worktree` | Git worktree metadata |
| `node_modules` | npm dependencies |
| `.DS_Store` | macOS metadata |
| `dist` | Build output |
| `target` | Rust/Cargo build output |
| `build` | Generic build output |
| `.next` | Next.js build |
| `.nuxt` | Nuxt.js build |
| `__pycache__` | Python bytecode |
| `.pytest_cache` | pytest cache |
| `.mypy_cache` | mypy cache |
| `venv`, `.venv` | Python virtual environments |
| `Pods` | CocoaPods dependencies |
| `DerivedData` | Xcode build data |

### Hidden Files

Files starting with `.` are excluded (e.g., `.gitignore`, `.env`).

## Limits

| Limit | Value | Behavior |
|-------|-------|----------|
| Max files | 50,000 | Returns `truncated: true` if exceeded |

## Caching Strategy

### Frontend Cache

```javascript
// Map<workspaceKey, {items, truncated, updatedAt}>
workspaceFileIndex = new Map();
```

- Cache is keyed by `project/workspace`
- Cache is invalidated on:
  - Workspace switch
  - Manual refresh via "Refresh File Index" command
- No automatic refresh (no file watcher)

### Cache Lifecycle

1. **First Cmd+P**: Request index from server, show loading state
2. **Subsequent Cmd+P**: Use cached index immediately
3. **Refresh command**: Clear cache, request fresh index

## Security

- Path validation ensures all returned paths are within workspace root
- Symlinks that escape workspace root are skipped
- Canonical path comparison prevents directory traversal

## Performance

- Indexing runs in `tokio::spawn_blocking` to avoid blocking async runtime
- Stack-based traversal (not recursive) to handle deep directories
- Results sorted alphabetically for consistent ordering

## Frontend Integration

### Quick Open (Cmd+P)

```javascript
// palette.js
function loadFiles() {
    const cachedIndex = window.tidyflow.getFileIndex(project, workspace);
    if (cachedIndex) {
        // Use cached index immediately
        renderItems(cachedIndex.items);
    } else {
        // Show loading, request from server
        showLoading();
        window.tidyflow.sendFileIndex(project, workspace);
    }
}
```

### Refresh Command

Available in Command Palette (Cmd+Shift+P):
- **Label**: "Refresh File Index"
- **Scope**: workspace
- **Category**: File

## Known Limitations

1. **No real-time updates**: File changes require manual refresh
2. **No content search**: Only file paths are indexed
3. **No custom ignore patterns**: Uses hardcoded ignore list
4. **Large repos**: May be slow on first index for very large codebases
