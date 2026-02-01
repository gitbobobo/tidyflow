# Editor Line Reveal Check (C2-1.5)

## Prerequisites
- [ ] TidyFlow app running
- [ ] Core server connected
- [ ] A file with changes (git diff shows content)

## Test Cases

### 1. Basic Line Navigation
- [ ] Click a `+` (added) line in diff view
- [ ] Editor tab opens/activates
- [ ] Cursor jumps to the exact line
- [ ] Line highlights yellow for 2 seconds

### 2. Deleted Line Handling
- [ ] Click a `-` (deleted) line in diff view
- [ ] Editor opens at nearest valid line (not line 0)

### 3. Boundary: Line Exceeds File
- [ ] Manually test with line > file length
- [ ] Should jump to last line, not crash

### 4. Existing Tab Reuse
- [ ] Open a file in editor manually
- [ ] Click a diff line for same file
- [ ] Tab reuses (no duplicate), jumps to line

### 5. Tab Switch + Re-click
- [ ] Click diff line -> editor opens at line X
- [ ] Switch to another tab
- [ ] Click different diff line -> jumps to line Y

### 6. Highlight Timing
- [ ] Highlight appears immediately on jump
- [ ] Highlight fades after ~2 seconds

### 7. Mode Switch
- [ ] From diff mode, click line
- [ ] Mode switches to editor automatically
