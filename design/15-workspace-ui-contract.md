# 15. Workspace UI Contract

## Overview

This document defines the UI contract for workspace-scoped tabs and the three-panel layout (Left Sidebar + Main Tabs + Right Tool Panel).

## Core Principle: Tabs Scoped to Workspace

**All tabs (Editor + Terminal) belong to a specific workspace.** This is a hard constraint.

### Tab Ownership Model

```
WorkspaceTabStore = Map<workspaceKey, TabSet>

workspaceKey = `${project}/${workspace}`

TabSet = {
  tabs: Map<tabId, TabInfo>,
  activeTabId: string | null,
  tabOrder: string[]  // for ordering in tab bar
}

TabInfo = {
  id: string,
  type: 'terminal' | 'editor',
  title: string,
  // Terminal-specific
  termId?: string,
  // Editor-specific
  filePath?: string,
  isDirty?: boolean,
  editorState?: any  // CodeMirror state snapshot
}
```

### Workspace Switching Behavior

When user switches from Workspace A to Workspace B:

1. **Save State**: Store Workspace A's tab set (including active tab, scroll positions, dirty states)
2. **Hide Tabs**: Hide all tab panes for Workspace A (do NOT destroy)
3. **Restore/Create**: Show Workspace B's tab set (restore if exists, create empty if new)
4. **Update Context**: Update right panel Explorer root to Workspace B

When switching back to Workspace A:
- Restore exact state: same tabs, same active tab, same scroll positions
- Terminal output preserved (xterm.js buffer intact)
- Editor content preserved (including unsaved changes)

### Tab Creation Rules

| Action | Allowed? | Notes |
|--------|----------|-------|
| Create Terminal Tab | Only if workspace selected | cwd = workspace root |
| Create Editor Tab | Only if workspace selected | file must be within workspace |
| Open file from Explorer | Yes | Opens in Main area as Editor Tab |
| Cross-workspace file open | **FORBIDDEN** | Must switch workspace first |

## Three-Panel Layout

```
+------------------+------------------------+------------------+
|                  |                        |                  |
|  LEFT SIDEBAR    |      MAIN AREA         |   RIGHT PANEL    |
|  (220px)         |      (flex: 1)         |   (280px)        |
|                  |                        |                  |
|  Projects/       |  [Tab Bar]             |  [Tool Icons]    |
|  Workspaces      |  +------------------+  |  Explorer|Search |
|  Tree            |  | Tab Content      |  |  |Git            |
|                  |  | (Editor/Terminal)|  |                  |
|                  |  +------------------+  |  [Tool Content]  |
|                  |                        |                  |
+------------------+------------------------+------------------+
```

### Left Sidebar (Permanent)

- Shows Projects/Workspaces tree
- Project nodes are collapsible
- Clicking workspace = select workspace context
- Selected workspace highlighted

### Main Area (Unified Tabs)

- Single tab bar for both Editor and Terminal tabs
- Tab types distinguished by icon:
  - Terminal: green icon (⌘ or similar)
  - Editor: blue icon (📄 or similar)
- Tab title format:
  - Terminal: `{workspace} · term` or `term @ {workspace}`
  - Editor: `{filename}` (with path tooltip)
- Dirty indicator: `*` suffix for unsaved editors
- Close button on each tab

### Right Tool Panel

- Tool icons at top: Explorer | Search | Git
- Only one tool view visible at a time
- Tool content scoped to current workspace

#### Explorer View
- File tree rooted at workspace root
- Lazy-load directories on expand
- Click file → open Editor Tab in Main area
- Click directory → expand/collapse

#### Search View
- Search input (disabled until workspace selected)
- File name search within workspace
- Click result → open Editor Tab

#### Git View
- Git status list (M/A/D/? indicators)
- Click file → open Editor Tab
- Refresh button to update status

## State Management

### Global State

```javascript
const state = {
  // Connection
  transport: WebSocketTransport,
  protocolVersion: number,
  capabilities: string[],

  // Projects/Workspaces
  projects: ProjectInfo[],
  workspaces: Map<projectName, WorkspaceInfo[]>,

  // Current context
  currentProject: string | null,
  currentWorkspace: string | null,
  currentWorkspaceRoot: string | null,

  // Tabs (scoped to workspace)
  workspaceTabs: Map<workspaceKey, TabSet>,

  // Right panel
  activeToolView: 'explorer' | 'search' | 'git',
  explorerTree: Map<path, FileEntry[]>,  // cached directory listings
  searchResults: SearchResult[],
  gitStatus: GitStatusEntry[]
};
```

### Tab Lifecycle

1. **Create Terminal Tab**
   - Send `term_create` to server
   - On `term_created` response: create xterm.js instance, add to TabSet
   - Switch to new tab

2. **Create Editor Tab**
   - Send `file_read` to server
   - On `file_read_result`: create CodeMirror instance, add to TabSet
   - Switch to new tab

3. **Close Tab**
   - Terminal: send `term_close`, dispose xterm.js on `term_closed`
   - Editor: if dirty, prompt save; dispose CodeMirror

4. **Switch Tab**
   - Hide current tab pane
   - Show target tab pane
   - Focus (terminal.focus() or editor.focus())

## API Requirements

### Existing APIs (sufficient)
- `file_list` - for Explorer tree
- `file_read` - for opening files
- `file_write` - for saving files
- `term_create` - for new terminals
- `term_close` - for closing terminals

### New APIs Needed

#### `git_status` (for Git View)
```json
// Request
{ "type": "git_status", "project": "...", "workspace": "..." }

// Response
{
  "type": "git_status_result",
  "project": "...",
  "workspace": "...",
  "items": [
    { "path": "src/main.rs", "status": "M" },
    { "path": "new-file.txt", "status": "?" }
  ]
}
```

Status codes: M (modified), A (added), D (deleted), ? (untracked), R (renamed)

#### `search_files` (for Search View - optional)
```json
// Request
{ "type": "search_files", "project": "...", "workspace": "...", "query": "..." }

// Response
{
  "type": "search_files_result",
  "project": "...",
  "workspace": "...",
  "query": "...",
  "items": [
    { "path": "src/main.rs", "matches": ["line 10: fn main()"] }
  ]
}
```

## Validation Rules

1. **Path Boundary**: All file operations must validate path is within workspace root
2. **Workspace Context**: Reject operations when no workspace selected
3. **Tab Ownership**: Verify tab belongs to current workspace before operations

## Error Handling

| Error | User Feedback |
|-------|---------------|
| No workspace selected | Show placeholder in Main area |
| File not found | Toast notification |
| File too large | Toast with size limit info |
| Path escape attempt | Silent reject + log |
| Git not initialized | Show "Not a git repository" in Git view |
