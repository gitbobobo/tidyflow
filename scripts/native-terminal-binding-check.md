# Native Terminal Binding Verification Checklist (Phase C1-1)

## Prerequisites
- [ ] Core server running (`cargo run` in core directory)
- [ ] App built and launched (`Cmd+R` in Xcode)

## Basic Terminal Binding
1. [ ] Launch app, select a workspace from sidebar
2. [ ] Cmd+T creates a new Terminal tab
3. [ ] Terminal tab shows xterm.js (not placeholder text)
4. [ ] Terminal displays workspace info on connect

## Terminal I/O
5. [ ] Type `pwd` and press Enter - shows current directory
6. [ ] Type `ls` and press Enter - lists files
7. [ ] Type `echo hello` - outputs "hello"
8. [ ] Arrow keys work for command history
9. [ ] Tab completion works

## Tab Switching
10. [ ] Create editor tab (open a file)
11. [ ] Switch to editor tab - editor content visible
12. [ ] Switch back to terminal tab - terminal still works
13. [ ] Terminal content preserved (previous output visible)

## Error Handling
14. [ ] Stop core server (Ctrl+C)
15. [ ] Terminal shows error state or message
16. [ ] Status bar shows disconnected indicator
17. [ ] Restart core server
18. [ ] Click reconnect or terminal recovers

## Status Bar
19. [ ] Terminal status bar shows session ID
20. [ ] Connection indicator (green/red dot) reflects state

## Known Limitations (Expected Behavior)
- Multiple terminal tabs share same session
- Sidebars hidden in terminal mode (by design)
- WebView shared between editor and terminal
