# Native Unified Diff Verification Checklist

## Prerequisites
- [ ] Core server running (`cargo run`)
- [ ] App built and launched
- [ ] Workspace selected with git repository

## Basic Functionality
1. [ ] Open diff tab from Git panel → Shows "Native Diff" badge
2. [ ] Diff content renders with line numbers (old/new columns)
3. [ ] Added lines show green background with `+` prefix
4. [ ] Removed lines show red background with `-` prefix
5. [ ] Context lines show no background with space prefix
6. [ ] Hunk headers (`@@`) show blue styling

## Mode Switching
7. [ ] Click "Staged" → Content updates to staged changes
8. [ ] Click "Working" → Content updates to working changes
9. [ ] Refresh button → Reloads current diff

## Line Navigation
10. [ ] Hover on context/add line → Shows highlight + cursor change
11. [ ] Click context line → Opens editor tab at that line
12. [ ] Click added line → Opens editor tab at that line
13. [ ] Editor highlights the target line briefly

## Edge Cases
14. [ ] Binary file → Shows "Binary file" message (no crash)
15. [ ] Deleted file → Lines not clickable, tooltip shows "File deleted"
16. [ ] Empty diff → Shows "No changes" message
17. [ ] Large diff (if available) → Shows truncation warning

## Tab Behavior
18. [ ] Switch to another tab → Diff tab preserved
19. [ ] Return to diff tab → Content still visible (from cache)
20. [ ] Close diff tab → No errors
