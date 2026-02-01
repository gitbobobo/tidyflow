# Command Palette & Keyboard Shortcuts

## Overview

TidyFlow implements a VS Code-style Command Palette with two modes:
- **Quick Open** (`Cmd+P`): File name search within current workspace
- **Command Palette** (`Cmd+Shift+P`): Command search and execution

## Trigger Keys

| Shortcut | Mode | Description |
|----------|------|-------------|
| `Cmd+P` | Quick Open | Search and open files by name |
| `Cmd+Shift+P` | Command Palette | Search and execute commands |

## Interaction Rules

1. **Opening**: Press trigger key to open palette
2. **Searching**: Type to filter items (fuzzy matching)
3. **Navigation**: `↑`/`↓` arrow keys to select
4. **Execution**: `Enter` to execute selected item
5. **Closing**: `Esc` or click outside to close
6. **Mouse**: Click any item to execute

## Command Categories

### Global Commands (Available without workspace)

| Command | Shortcut | Description |
|---------|----------|-------------|
| Show All Commands | `Cmd+Shift+P` | Open command palette |
| Show Explorer | `Cmd+1` | Switch to Explorer panel |
| Show Search | `Cmd+2` | Switch to Search panel |
| Show Git | `Cmd+3` | Switch to Git panel |
| Refresh Projects | - | Reload projects list from core |
| Reconnect to Core | - | Re-establish WebSocket connection |

### Workspace-Scoped Commands (Require selected workspace)

| Command | Shortcut | Description |
|---------|----------|-------------|
| Quick Open File | `Cmd+P` | Open file search |
| New Terminal | `Cmd+T` | Create new terminal tab |
| Close Tab | `Cmd+W` | Close current tab |
| Next Tab | `Ctrl+Tab` | Switch to next tab |
| Previous Tab | `Ctrl+Shift+Tab` | Switch to previous tab |
| Save File | `Cmd+S` | Save current editor |
| Refresh Explorer | - | Reload file tree |
| Refresh File Index | - | Rebuild Quick Open index |

### Alternative Tab Navigation

| Shortcut | Description |
|----------|-------------|
| `Cmd+Alt+→` | Next tab |
| `Cmd+Alt+←` | Previous tab |

## File Index Strategy

**Chosen Strategy**: Lazy collection from Explorer cache

### How It Works

1. File index is built from `allFilePaths` array maintained by main.js
2. This array is populated as directories are expanded in Explorer
3. Index is workspace-scoped (clears on workspace switch)
4. Manual refresh available via "Refresh File Index" command

### Why This Approach

- **No additional API calls**: Reuses existing Explorer data
- **Incremental**: Index grows as user explores directories
- **Memory efficient**: Only indexes visited paths
- **Fast**: No blocking operations on workspace switch

### Trade-offs

- Files in unexpanded directories won't appear in Quick Open
- User must expand directories in Explorer first, or use "Refresh File Index"

## Implementation Details

### Files Modified/Created

| File | Purpose |
|------|---------|
| `palette.js` | Command palette module (new) |
| `index.html` | Added palette CSS and script include |
| `main.js` | Exposed `getAllFilePaths()` API |

### Architecture

```
palette.js
├── Command Registry (registerCommand, getCommands)
├── File Index (updateFileIndex, collectFilesFromExplorer)
├── Fuzzy Search (fuzzyMatch, highlightMatches)
├── Palette UI (createPaletteUI, openPalette, closePalette)
└── Keyboard Shortcuts (registerShortcut, handleGlobalKeydown)
```

### API Exposed

```javascript
window.tidyflowPalette = {
    open(mode),           // 'command' or 'file'
    close(),
    isOpen(),
    registerCommand(id, config),
    registerShortcut(key, handler, options),
    updateFileIndex(),
    getFileIndex()
};
```

## Known Limitations

1. **File index is lazy**: Only includes files from expanded Explorer directories
2. **No file content search**: Only searches file names, not contents
3. **No recent files**: No MRU (most recently used) file list
4. **No workspace history**: Cannot switch workspaces via palette
5. **Git panel is placeholder**: Git commands show panel but no real functionality
6. **No custom keybindings**: Shortcuts are hardcoded
7. **Single-level fuzzy match**: No advanced scoring like VS Code
8. **No command history**: Cannot repeat last command
