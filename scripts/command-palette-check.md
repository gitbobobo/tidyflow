# Command Palette Verification Checklist

## Prerequisites
- TidyFlow app running with core connected
- At least one project with workspaces available

## Test Cases

### 1. Global Commands (No Workspace Selected)

- [ ] `Cmd+Shift+P` opens command palette
- [ ] `Cmd+P` opens Quick Open (shows "Select a workspace first")
- [ ] `Cmd+1` switches to Explorer panel
- [ ] `Cmd+2` switches to Search panel
- [ ] `Cmd+3` switches to Git panel
- [ ] "Refresh Projects" command works from palette
- [ ] "Reconnect to Core" command works from palette
- [ ] Workspace-scoped commands show as disabled in palette

### 2. Workspace Selection

- [ ] Select a workspace from left sidebar
- [ ] Terminal tab opens automatically
- [ ] Explorer shows workspace files

### 3. Quick Open (Cmd+P)

- [ ] `Cmd+P` opens file search mode (no ">" prefix)
- [ ] Typing filters file list
- [ ] Arrow keys navigate list
- [ ] Enter opens selected file as editor tab
- [ ] Esc closes palette
- [ ] Click on item opens file

### 4. Command Palette (Cmd+Shift+P)

- [ ] `Cmd+Shift+P` opens command mode (">" prefix)
- [ ] All commands visible (global + workspace-scoped)
- [ ] Shortcut hints displayed for commands
- [ ] Fuzzy search works (e.g., "new term" finds "New Terminal")
- [ ] Enter executes selected command

### 5. Tab Management Shortcuts

- [ ] `Cmd+T` creates new terminal tab
- [ ] `Cmd+W` closes current tab
- [ ] `Ctrl+Tab` switches to next tab
- [ ] `Ctrl+Shift+Tab` switches to previous tab
- [ ] `Cmd+Alt+→` switches to next tab
- [ ] `Cmd+Alt+←` switches to previous tab

### 6. File Operations

- [ ] `Cmd+S` saves current editor (when dirty)
- [ ] "Refresh Explorer" command reloads file tree
- [ ] "Refresh File Index" rebuilds Quick Open index

### 7. Edge Cases

- [ ] Palette closes when clicking outside
- [ ] Empty search shows all items
- [ ] No results shows "No results found"
- [ ] Disabled items cannot be selected
- [ ] Shortcuts don't trigger when typing in input fields

## Quick Smoke Test (5 steps)

1. Launch app, press `Cmd+Shift+P` → palette opens
2. Select workspace, press `Cmd+T` → new terminal
3. Press `Cmd+P`, type filename → file opens
4. Press `Cmd+W` → tab closes
5. Press `Cmd+1/2/3` → panels switch
