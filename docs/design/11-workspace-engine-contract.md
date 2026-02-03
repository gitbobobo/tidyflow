# TidyFlow - Workspace Engine v1 Contract

> Version: 1.0
> Created: 2026-01-31

## Overview

Workspace Engine v1 provides project and workspace management using git worktree for isolation. This document defines the API contract, directory layout, state schema, and state machine.

---

## CLI API

### Import Project

```bash
# From local path
tidyflow-core import --name <name> --path <local_path>

# From git URL
tidyflow-core import --name <name> --git <url> [--branch <branch>]
```

**Behavior:**
- Validates path exists and is a git repository
- Loads `.tidyflow.toml` if present
- Detects default branch from git
- Persists project metadata to state

### Create Workspace

```bash
tidyflow-core ws create --project <name> --workspace <ws_name> [--from-branch <branch>] [--no-setup]
```

**Behavior:**
1. Creates git worktree at `~/.tidyflow/workspaces/<ws_name>`
2. Creates new branch `tidy/<random-two-words>` from source branch, workspace name matches the random words (without tidy/ prefix)
3. Runs setup steps from `.tidyflow.toml` (unless `--no-setup`)
4. Updates workspace status based on setup result

### List Projects/Workspaces

```bash
tidyflow-core list projects
tidyflow-core list workspaces --project <name>
```

### Show Workspace

```bash
tidyflow-core ws show --project <name> --workspace <ws_name>
```

**Output:** Workspace root path to stdout (for scripting), details to stderr.

### Run Setup

```bash
tidyflow-core ws setup --project <name> --workspace <ws_name>
```

**Behavior:** Re-runs setup steps for an existing workspace.

### Remove Workspace

```bash
tidyflow-core ws remove --project <name> --workspace <ws_name>
```

**Behavior:**
1. Runs `git worktree remove --force`
2. Removes workspace from state

---

## Directory Layout

### State File Location

```
~/.tidyflow/state.json
```

### Project Structure

```
<project_root>/
├── .git/                    # Main git directory
├── .tidyflow.toml           # Project configuration (optional)
└── src/                     # Project source code
    ...
```

### Worktree Path Pattern

```
~/.tidyflow/workspaces/<workspace_name>/
```

---

## State Schema

### state.json

```json
{
  "version": 1,
  "last_updated": "2026-01-31T12:00:00Z",
  "projects": {
    "<project_name>": {
      "name": "string",
      "root_path": "/absolute/path",
      "remote_url": "string | null",
      "default_branch": "main",
      "created_at": "ISO8601",
      "workspaces": {
        "<workspace_name>": {
          "name": "string",
          "worktree_path": "/absolute/path",
          "branch": "tidy/<random-name>",
          "status": "creating | initializing | ready | setup_failed | destroying",
          "created_at": "ISO8601",
          "last_accessed": "ISO8601",
          "setup_result": {
            "success": true,
            "steps_total": 3,
            "steps_completed": 3,
            "last_error": "string | null",
            "completed_at": "ISO8601"
          }
        }
      }
    }
  }
}
```

### Version Migration Strategy

| Version | Changes | Migration |
|---------|---------|-----------|
| 1 | Initial schema | N/A |

**Backward Compatibility Rules:**
1. New fields MUST have default values
2. Removed fields MUST be ignored on load
3. Version number increments only for breaking changes
4. Migration code runs automatically on load if version < current

---

## Workspace State Machine

```
┌──────────┐
│ Creating │ ─── worktree created ───┐
└──────────┘                         │
                                     ▼
                              ┌──────────────┐
                              │ Initializing │
                              └──────────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                │
                    ▼                ▼                ▼
             ┌───────────┐    ┌───────────┐    ┌─────────────┐
             │   Ready   │    │SetupFailed│    │ (no setup)  │
             └───────────┘    └───────────┘    │   Ready     │
                    │                │         └─────────────┘
                    │                │
                    │    ┌───────────┘
                    │    │ re-run setup
                    │    ▼
                    │  ┌──────────────┐
                    │  │ Initializing │
                    │  └──────────────┘
                    │
                    ▼
             ┌────────────┐
             │ Destroying │
             └────────────┘
                    │
                    ▼
               (removed)
```

### State Transitions

| From | To | Trigger |
|------|----|---------|
| - | Creating | `ws create` command |
| Creating | Initializing | Worktree created, setup starts |
| Creating | Ready | Worktree created, no setup |
| Initializing | Ready | Setup completes successfully |
| Initializing | SetupFailed | Setup step fails |
| SetupFailed | Initializing | `ws setup` command |
| Ready | Destroying | `ws remove` command |
| SetupFailed | Destroying | `ws remove` command |

---

## Setup Execution

### Step Execution Flow

1. Load `.tidyflow.toml` from workspace root
2. For each step in `setup.steps`:
   a. Check condition (skip if not met)
   b. Prepare environment (inherit + custom vars + PATH modifications)
   c. Execute command via shell with timeout
   d. Record stdout/stderr/exit_code
   e. If failed and `continue_on_error=false`, stop
3. Update workspace status and setup_result

### Security Constraints

- All commands execute with `cwd` set to workspace directory
- No `cd` to paths outside workspace
- Output truncated to 10KB per step
- Timeout enforced per step and total

### Step Result Schema

```json
{
  "name": "Install deps",
  "command": "npm install",
  "success": true,
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "skipped": false,
  "skip_reason": null,
  "started_at": "ISO8601",
  "completed_at": "ISO8601"
}
```

---

## Error Handling

### Error Types

| Error | Code | Recovery |
|-------|------|----------|
| ProjectNotFound | - | Import project first |
| WorkspaceNotFound | - | Create workspace first |
| AlreadyExists | - | Use different name |
| GitError | - | Check git status, fix manually |
| SetupFailed | - | Fix issue, run `ws setup` |

### Failure Modes

1. **Git worktree creation fails**: State not modified, error returned
2. **Setup step fails**: Workspace marked `setup_failed`, can retry
3. **State file corrupted**: Backup at `~/.tidyflow/state.json.bak`

---

## Future Extensions (Not in v1)

- [ ] HTTP/WebSocket API for UI integration
- [ ] Workspace templates
- [ ] Parallel setup execution
- [ ] Setup step dependencies
- [ ] Workspace snapshots
