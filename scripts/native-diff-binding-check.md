# Native Diff Binding Check (Phase C2-1)

## Prerequisites
- [ ] Core server running (`cargo run`)
- [ ] App built and launched
- [ ] Workspace selected with git repository

## Verification Steps

### 1. Open Diff Tab from Git Panel
- [ ] Click Git icon in right sidebar
- [ ] Click a modified file in the list
- [ ] Verify: Diff Tab opens with file content
- [ ] Verify: Tab title shows "Diff: filename"
- [ ] Verify: Diff content displays (not placeholder)

### 2. Working/Staged Mode Toggle
- [ ] With Diff Tab open, click "Staged" in toolbar
- [ ] Verify: Diff content updates (may show "No changes" if nothing staged)
- [ ] Click "Working" to switch back
- [ ] Verify: Diff content shows working changes again

### 3. Diff Line Click → Editor
- [ ] Click any line in the diff view
- [ ] Verify: Editor Tab opens for that file
- [ ] Verify: Editor shows file content (not diff)

### 4. Tab Switching Persistence
- [ ] Open a Diff Tab
- [ ] Switch to Terminal Tab
- [ ] Switch back to Diff Tab
- [ ] Verify: Diff content still displays correctly

### 5. Multiple Diff Tabs
- [ ] Open diff for file A
- [ ] Open diff for file B (from Git panel)
- [ ] Verify: Both tabs exist
- [ ] Switch between them
- [ ] Verify: Each shows correct file's diff

### 6. Mode Persistence
- [ ] Open Diff Tab, set to "Staged"
- [ ] Switch to another tab
- [ ] Switch back to Diff Tab
- [ ] Verify: Mode is still "Staged"

### 7. Error Handling
- [ ] Open diff for a file
- [ ] Delete the file externally
- [ ] Click refresh in diff toolbar
- [ ] Verify: Shows appropriate message (not crash)

## Known Limitations
1. Line number not passed to editor (opens at line 1)
2. Unified/Split toggle is Web-only
3. Deleted files show disabled "Open file" button
