# Native Git Stage/Unstage Check (Phase C3-2a)

## Prerequisites
- [ ] Core running (`cargo run` in core/)
- [ ] App running (Xcode build)
- [ ] Workspace with git repo selected

## Stage Single File
- [ ] Modify a tracked file
- [ ] Git panel shows file with M status
- [ ] Hover over row shows green + button
- [ ] Click Stage button
- [ ] Spinner appears during operation
- [ ] Toast shows "Staged <filename>"
- [ ] Git status refreshes

## Stage Untracked File
- [ ] Create new file in workspace
- [ ] Git panel shows file with ?? status
- [ ] Click Stage button
- [ ] File status changes (no longer ??)

## Stage All
- [ ] Have multiple modified/untracked files
- [ ] Click "Stage All" in toolbar
- [ ] All files staged
- [ ] Toast shows "Staged all files"

## Unstage All
- [ ] Have staged files
- [ ] Click "Unstage All" in toolbar
- [ ] All files unstaged
- [ ] Toast shows "Unstaged all files"

## Diff Tab Integration
- [ ] Open diff tab for a file
- [ ] Stage the file from git panel
- [ ] Switch diff tab to "Staged" mode
- [ ] Staged diff shows content

## Error Handling
- [ ] Disconnect from core
- [ ] Try to stage - shows "Disconnected" toast
- [ ] Non-git workspace shows disabled buttons

## UI States
- [ ] Buttons disabled during in-flight operation
- [ ] Toast auto-dismisses after 2 seconds
- [ ] Stage All disabled when no unstaged changes
