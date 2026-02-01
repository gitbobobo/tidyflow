# Native Git Panel Verification Checklist (Phase C3-1)

## Prerequisites
- [ ] Core server running on port 47999
- [ ] App connected (green status indicator)
- [ ] At least one workspace is a git repository with changes

## Basic Display
- [ ] Switch to Git tool (Cmd+3 or click git icon)
- [ ] Loading spinner appears briefly
- [ ] Status list displays with file paths and status badges
- [ ] Status badges show correct colors (M=orange, A=green, D=red, ??=gray)

## Filtering
- [ ] Click magnifying glass to show filter input
- [ ] Type partial filename - list filters in real-time
- [ ] Clear filter - full list returns
- [ ] Filter with no matches shows "No Matches" empty state

## Refresh
- [ ] Click refresh button (arrow.clockwise)
- [ ] Loading indicator appears in footer
- [ ] List updates with fresh data
- [ ] "Updated just now" shows in footer

## Open Diff Tab
- [ ] Click any modified file (M status)
- [ ] Diff tab opens in center content area
- [ ] Native Diff badge visible in tab
- [ ] Diff content loads correctly

## Workspace Switching
- [ ] Switch to different workspace
- [ ] Git panel updates to show that workspace's status
- [ ] Previous workspace status cached (switch back is instant)

## Empty States
- [ ] Non-git workspace shows "Not a Git Repository"
- [ ] Clean workspace shows "No Changes"
- [ ] Disconnected state shows "Disconnected"

## Edge Cases
- [ ] Deleted file (D) can be clicked to open diff
- [ ] Renamed file (R) shows rename info
- [ ] Untracked file (??) displays correctly
- [ ] Long file paths truncate properly

## Performance
- [ ] Initial load completes within 2 seconds
- [ ] Filter is responsive (no lag)
- [ ] Scrolling is smooth with 50+ files
