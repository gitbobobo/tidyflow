# 16. Right Panel Tools Specification

## Overview

The right panel provides three tool views: Explorer, Search, and Git. All views are scoped to the currently selected workspace.

**Related**: [19-git-tools.md](./19-git-tools.md) - Git Tools API (git_status, git_diff, Diff Tab)

## Tool Views

### 1. Explorer View

**Purpose**: Browse and open files within the workspace.

**Features**:
- File tree rooted at workspace root
- Lazy-load directories (expand on click)
- File icons based on type
- Click file → open in Editor Tab
- Click directory → toggle expand/collapse

**API**: Uses existing `file_list` API

```json
// Request
{ "type": "file_list", "project": "...", "workspace": "...", "path": "." }

// Response
{
  "type": "file_list_result",
  "project": "...",
  "workspace": "...",
  "path": ".",
  "items": [
    { "name": "src", "is_dir": true, "size": 0 },
    { "name": "README.md", "is_dir": false, "size": 1234 }
  ]
}
```

**UI States**:
- No workspace: "No workspace selected"
- Loading: Spinner
- Empty directory: "Empty directory"
- Error: Error message

### 2. Search View

**Purpose**: Find files by name within the workspace.

**Features**:
- Text input for search query
- Real-time filtering as user types
- Results show file path with match highlighted
- Click result → open in Editor Tab

**Implementation**: Client-side filtering of cached file list (MVP)

For MVP, we use client-side search:
1. Cache all file paths from recursive `file_list` calls
2. Filter paths matching query (case-insensitive substring)
3. Display matching results

**Future Enhancement**: Server-side `search_files` API for content search.

**UI States**:
- No workspace: Input disabled, "No workspace selected"
- No query: "Enter a search term"
- No results: "No files found"
- Results: List of matching files

### 3. Git View

**Purpose**: Show git status of workspace files.

**Features**:
- List of changed files with status indicator
- Status colors: M (yellow), A (green), D (red), ? (gray)
- Click file → open in Editor Tab
- Refresh button to update status

**API**: New `git_status` API

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
  ],
  "branch": "main",
  "is_git_repo": true
}
```

**Status Codes**:
| Code | Meaning | Color |
|------|---------|-------|
| M | Modified | Yellow (#e8ab53) |
| A | Added | Green (#89d185) |
| D | Deleted | Red (#f48771) |
| ? | Untracked | Gray (#808080) |
| R | Renamed | Blue (#519aba) |
| C | Copied | Blue (#519aba) |
| U | Updated but unmerged | Orange (#cc6633) |

**UI States**:
- No workspace: "No workspace selected"
- Not a git repo: "Not a git repository"
- No changes: "Working tree clean"
- Loading: Spinner
- Error: Error message

## Protocol Extensions

### git_status (New)

Add to `protocol.rs`:

```rust
// ClientMessage
GitStatus {
    project: String,
    workspace: String,
},

// ServerMessage
GitStatusResult {
    project: String,
    workspace: String,
    items: Vec<GitStatusEntry>,
    branch: String,
    is_git_repo: bool,
},

// Data type
pub struct GitStatusEntry {
    pub path: String,
    pub status: String,  // "M", "A", "D", "?", etc.
}
```

### Implementation in ws.rs

```rust
ClientMessage::GitStatus { project, workspace } => {
    let state = app_state.lock().await;
    match state.get_project(&project) {
        Some(p) => match p.get_workspace(&workspace) {
            Some(w) => {
                let root = w.worktree_path.clone();
                drop(state);

                // Run git status --porcelain
                let output = std::process::Command::new("git")
                    .args(&["-C", &root.to_string_lossy(), "status", "--porcelain"])
                    .output();

                match output {
                    Ok(out) => {
                        let stdout = String::from_utf8_lossy(&out.stdout);
                        let items: Vec<GitStatusEntry> = stdout
                            .lines()
                            .filter_map(|line| {
                                if line.len() >= 3 {
                                    let status = line[0..2].trim().to_string();
                                    let path = line[3..].to_string();
                                    Some(GitStatusEntry { path, status })
                                } else {
                                    None
                                }
                            })
                            .collect();

                        // Get current branch
                        let branch_output = std::process::Command::new("git")
                            .args(&["-C", &root.to_string_lossy(), "branch", "--show-current"])
                            .output();
                        let branch = branch_output
                            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                            .unwrap_or_default();

                        send_message(socket, &ServerMessage::GitStatusResult {
                            project,
                            workspace,
                            items,
                            branch,
                            is_git_repo: true,
                        }).await?;
                    }
                    Err(_) => {
                        send_message(socket, &ServerMessage::GitStatusResult {
                            project,
                            workspace,
                            items: vec![],
                            branch: String::new(),
                            is_git_repo: false,
                        }).await?;
                    }
                }
            }
            None => { /* error handling */ }
        },
        None => { /* error handling */ }
    }
}
```

## UI Implementation

### Tool Icon Bar

```html
<div id="tool-icons">
    <button class="tool-icon active" data-tool="explorer" title="Explorer">📁</button>
    <button class="tool-icon" data-tool="search" title="Search">🔍</button>
    <button class="tool-icon" data-tool="git" title="Git">⎇</button>
</div>
```

### Tool View Switching

```javascript
function switchToolView(toolName) {
    // Update icon states
    document.querySelectorAll('.tool-icon').forEach(icon => {
        icon.classList.toggle('active', icon.dataset.tool === toolName);
    });

    // Update view visibility
    document.querySelectorAll('.tool-view').forEach(view => {
        view.classList.toggle('active', view.id === `${toolName}-view`);
    });

    state.activeToolView = toolName;

    // Refresh view content if needed
    if (toolName === 'explorer') refreshExplorer();
    if (toolName === 'git') refreshGitStatus();
}
```

## Security Considerations

1. **Path Validation**: All file paths must be validated against workspace root
2. **Git Command Safety**: Only run read-only git commands (status, branch)
3. **No Shell Injection**: Use array args, not string concatenation for commands
