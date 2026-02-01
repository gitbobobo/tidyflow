# Workspace UI Behavior Verification Checklist

## Prerequisites
- [ ] Rust Core running (`./scripts/run-core.sh`)
- [ ] macOS App running (`./scripts/run-app.sh`)
- [ ] At least 2 projects with workspaces configured

## Test Cases

### 1. Initial State
- [ ] Left sidebar shows "Projects" header
- [ ] Main area shows placeholder "Select a workspace to start"
- [ ] Right panel shows Explorer view with "No workspace selected"
- [ ] New Terminal button is disabled
- [ ] Search input is disabled

### 2. Select Workspace
- [ ] Click a workspace in left sidebar
- [ ] Workspace is highlighted in tree
- [ ] Terminal tab is created automatically
- [ ] Terminal shows workspace info (project/workspace, root path)
- [ ] New Terminal button is enabled
- [ ] Explorer shows workspace file tree
- [ ] Search input is enabled

### 3. Create Terminal Tab
- [ ] Click ⌘ button in tab bar
- [ ] New terminal tab appears
- [ ] Tab shows workspace name
- [ ] Tab has green terminal icon
- [ ] Terminal is focused and ready for input

### 4. Open File in Editor
- [ ] Click a file in Explorer
- [ ] Editor tab is created
- [ ] Tab shows filename with blue icon
- [ ] File content is displayed in editor
- [ ] Editor is focused

### 5. Edit and Save File
- [ ] Make changes in editor
- [ ] Tab shows dirty indicator (*)
- [ ] Save button is enabled
- [ ] Press Cmd+S to save
- [ ] Dirty indicator disappears
- [ ] Status bar shows "Saved: filename"

### 6. Close Tab
- [ ] Click × on a tab
- [ ] Tab is removed
- [ ] If dirty editor, confirm dialog appears
- [ ] For terminal, server receives term_close

### 7. Switch Workspace (Core Feature)
- [ ] Open multiple tabs in Workspace A
- [ ] Click different workspace (Workspace B) in sidebar
- [ ] All Workspace A tabs are hidden
- [ ] Workspace B tabs are shown (or placeholder if empty)
- [ ] Explorer shows Workspace B files
- [ ] Click back to Workspace A
- [ ] All Workspace A tabs are restored
- [ ] Active tab is restored
- [ ] Terminal output is preserved
- [ ] Editor content is preserved (including unsaved changes)

### 8. Tool Panel Switching
- [ ] Click Search icon
- [ ] Search view is shown
- [ ] Explorer view is hidden
- [ ] Click Git icon
- [ ] Git view is shown
- [ ] Click Explorer icon
- [ ] Explorer view is shown

### 9. Search Functionality
- [ ] Type in search input
- [ ] Results show matching files
- [ ] Click result opens file in editor

### 10. Error Handling
- [ ] Try to open file without workspace selected → blocked
- [ ] Try to create terminal without workspace → blocked
- [ ] Close all tabs → placeholder is shown

## Expected Behavior Summary

| Action | Result |
|--------|--------|
| Select workspace | Creates terminal, updates Explorer |
| Switch workspace | Saves tabs, restores target workspace tabs |
| New terminal | Creates tab bound to current workspace |
| Open file | Creates editor tab bound to current workspace |
| Close tab | Removes from current workspace's tab set |
| Tool icon click | Switches right panel view |

## Known Limitations

1. Git status API not yet implemented (shows placeholder)
2. Search is client-side file name only (no content search)
3. No drag-and-drop tab reordering
