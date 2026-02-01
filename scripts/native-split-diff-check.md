# Native Split Diff Check (Phase C2-2b-1)

## Prerequisites
- [ ] App builds without errors
- [ ] Have a file with modifications (working or staged)

## Basic Split View
- [ ] Open a modified file's Diff Tab
- [ ] Toolbar shows "Unified / Split" segmented picker
- [ ] Click "Split" - view changes to two columns
- [ ] Left column shows old lines (- and context)
- [ ] Right column shows new lines (+ and context)
- [ ] "Split View" badge appears next to "Native Diff" badge

## Navigation
- [ ] Click a + line in right column → Editor opens at correct line
- [ ] Click a context line in right column → Editor opens at correct line
- [ ] Click a - line in left column → Editor opens at nearest line
- [ ] Hover shows "Click to go to line X" tooltip

## Toggle Back
- [ ] Click "Unified" → Returns to single-column view
- [ ] All navigation still works in unified mode

## Edge Cases
- [ ] Binary file: Split toggle disabled, tooltip shows "Binary file"
- [ ] Large diff (>5000 lines): Split toggle disabled, tooltip shows reason
- [ ] Deleted file: Navigation disabled, tooltip explains

## State Persistence
- [ ] Switch to Split, change to another tab, return → Still in Split mode
- [ ] Different diff tabs can have different view modes

## Status Bar
- [ ] Shows "Split" or "Unified" indicator
- [ ] Shows "Working Changes" or "Staged Changes"
