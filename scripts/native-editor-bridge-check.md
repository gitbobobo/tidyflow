# Phase B-3b: Native Editor Bridge Verification

## Prerequisites
- [ ] Core server running (`cargo run` in core/)
- [ ] App built and launched

## Basic Flow
1. [ ] Launch app, wait for "Connected" status
2. [ ] Cmd+P opens Quick Open palette
3. [ ] Select a file (e.g., README.md)
4. [ ] Editor tab created with file name in tab strip
5. [ ] WebView shows file content (not placeholder)
6. [ ] Status bar shows file path

## Save Flow
7. [ ] Modify text in editor
8. [ ] Cmd+S triggers save
9. [ ] Status bar shows "Saving..." then "Saved"
10. [ ] Dirty indicator clears

## Tab Switching
11. [ ] Cmd+T creates Terminal tab
12. [ ] Terminal placeholder visible
13. [ ] Click Editor tab to switch back
14. [ ] Editor content still visible

## Error Handling
15. [ ] Disconnect core server
16. [ ] Cmd+S shows error in status bar
17. [ ] Reconnect and retry works

## Keyboard Shortcuts
18. [ ] Cmd+P works when WebView focused
19. [ ] Cmd+Shift+P works when WebView focused
20. [ ] Cmd+W closes active tab
