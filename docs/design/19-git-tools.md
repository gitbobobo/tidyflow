# 19. Git Tools Specification

## Overview

Git Tools provides workspace-scoped git status and diff functionality. The right panel shows git status list, and clicking a file opens a Diff Tab in the center area (alongside Editor/Terminal tabs).

**Related**: [16-right-panel-tools.md](./16-right-panel-tools.md) - Git View UI

## Protocol Messages

### Client → Server

#### git_status
Request git status for a workspace.

```json
{
  "type": "git_status",
  "project": "my-project",
  "workspace": "main"
}
```

#### git_diff
Request unified diff for a specific file.

```json
{
  "type": "git_diff",
  "project": "my-project",
  "workspace": "main",
  "path": "src/main.rs",
  "base": "HEAD",
  "mode": "working"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| project | string | yes | Project name |
| workspace | string | yes | Workspace name |
| path | string | yes | Relative path to file |
| base | string | no | Base ref for diff (default: "HEAD") |
| mode | string | no | "working" or "staged" (default: "working") |

### Server → Client

#### git_status_result

```json
{
  "type": "git_status_result",
  "project": "my-project",
  "workspace": "main",
  "repo_root": "/path/to/repo",
  "items": [
    { "path": "src/main.rs", "code": "M", "orig_path": null },
    { "path": "new-file.txt", "code": "??", "orig_path": null },
    { "path": "renamed.txt", "code": "R", "orig_path": "old-name.txt" }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| repo_root | string | Git repository root path (empty if not a git repo) |
| items | array | List of changed files |
| items[].path | string | File path relative to workspace root |
| items[].code | string | Status code (M, A, D, ??, R, C) |
| items[].orig_path | string? | Original path for renamed/copied files |

**Status Codes**:
| Code | Meaning | Description |
|------|---------|-------------|
| M | Modified | File has been modified |
| A | Added | File is staged for addition |
| D | Deleted | File has been deleted |
| ?? | Untracked | File is not tracked by git |
| R | Renamed | File has been renamed |
| C | Copied | File has been copied |

#### git_diff_result

```json
{
  "type": "git_diff_result",
  "project": "my-project",
  "workspace": "main",
  "path": "src/main.rs",
  "code": "M",
  "format": "unified",
  "text": "diff --git a/src/main.rs b/src/main.rs\n...",
  "is_binary": false,
  "truncated": false,
  "mode": "working"
}
```

| Field | Type | Description |
|-------|------|-------------|
| path | string | File path |
| code | string | Status code |
| format | string | Always "unified" for this version |
| text | string | Unified diff text |
| is_binary | bool | True if file is binary |
| truncated | bool | True if diff was truncated due to size |
| mode | string | "working" or "staged" |

## Implementation Details

### git status

Uses `git status --porcelain=v1 -z` for stable parsing:
- `-z` uses NUL separators (handles filenames with spaces)
- `--porcelain=v1` provides machine-readable output

**Parsing Format**:
```
XY PATH\0
XY ORIG_PATH\0PATH\0  (for renames/copies)
```

Where XY is the two-character status code.

### git diff

**For tracked files (M, A, D)**:
```bash
git diff -- <path>
```

**For untracked files (??)**:
```bash
git diff --no-index /dev/null -- <path>
```

**For deleted files (D)**:
```bash
git diff -- <path>
```

### Diff Mode

The `mode` parameter controls which changes are shown:

| Mode | Command | Description |
|------|---------|-------------|
| working | `git diff -- <path>` | Unstaged changes (working tree vs index) |
| staged | `git diff --cached -- <path>` | Staged changes (index vs HEAD) |

**Default**: `working`

**Untracked files in staged mode**: Returns empty diff (untracked files have no staged changes).

### Size Limits

- Maximum diff size: 1MB (1,048,576 bytes)
- If exceeded: `truncated=true`, text contains first 1MB

### Security

1. **Path Validation**: All paths must be within workspace root
2. **No Path Escape**: Reject paths containing `..` that escape workspace
3. **CWD Fixed**: All git commands run with cwd = workspace_root
4. **Read-Only**: Only read-only git commands (status, diff)

### Error Handling

If workspace is not in a git repository:
- `git_status_result`: `repo_root=""`, `items=[]`
- `git_diff_result`: Return error message

## Frontend Integration

### Diff Tab

Diff Tab is a new tab type (`type: "diff"`) that:
- Belongs to current workspace's tab set
- Shows unified diff in monospace font
- Displays file path, status code, and refresh button
- Handles truncated/binary file states

**Tab ID Format**: `diff-{path-sanitized}`

**Tab Title**: `{filename} (diff)` or `Diff: {filename}`

### Git View Click Handler

When user clicks a file in Git status list:
1. Create/activate Diff Tab for that file
2. Send `git_diff` request
3. Display diff content in tab

### Diff Tab Refresh

Refresh button re-sends `git_diff` request and updates content.

## UI States

### Git Status List
- No workspace: "No workspace selected"
- Not a git repo: "Not a git repository"
- No changes: "Working tree clean"
- Loading: Spinner
- Error: Error message

### Diff Tab
- Loading: "Loading diff..."
- Binary file: "Binary file diff not supported"
- Truncated: "Diff too large, truncated to 1MB"
- Empty diff: "No changes"
- Error: Error message

## Future Enhancements

1. **Split Diff View**: Side-by-side diff rendering
2. **Line Navigation**: Click diff line to open file at that line
3. **Syntax Highlighting**: Language-aware diff highlighting
