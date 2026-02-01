# Native Terminal Multi-Session Verification Checklist

## Prerequisites
- [ ] Core server running (`cargo run` in core directory)
- [ ] App built and running

## Basic Multi-Tab Tests

1. [ ] Select a workspace from sidebar
2. [ ] Cmd+T creates Tab1 (terminal)
3. [ ] Run `echo TAB1 && sleep 1` in Tab1
4. [ ] Cmd+T creates Tab2 (terminal)
5. [ ] Run `echo TAB2 && sleep 1` in Tab2
6. [ ] Switch to Tab1 - shows "TAB1" output only
7. [ ] Switch to Tab2 - shows "TAB2" output only
8. [ ] No output mixing between tabs

## Session Independence

9. [ ] In Tab1: run `pwd` - note output
10. [ ] In Tab2: run `cd /tmp && pwd` - shows /tmp
11. [ ] Switch to Tab1: run `pwd` - still original dir
12. [ ] Sessions maintain independent state

## Tab Close / Kill

13. [ ] Close Tab1 (click X or Cmd+W)
14. [ ] Tab2 still functional
15. [ ] Check core logs: session count decreased
16. [ ] Create new Tab3 - works normally

## Workspace Isolation

17. [ ] Switch to different workspace
18. [ ] Create terminal tab in new workspace
19. [ ] Run `echo WORKSPACE2`
20. [ ] Switch back to original workspace
21. [ ] Original tabs unaffected

## Edge Cases

22. [ ] Rapid tab switching (no crash)
23. [ ] Close all tabs, create new one (works)
24. [ ] Disconnect core, tabs show error state
25. [ ] Reconnect, activate tab - respawns session

## Status Bar

26. [ ] Status bar shows session ID prefix
27. [ ] Connection indicator green when connected
28. [ ] Error state shown on disconnect

## Pass Criteria
- All 28 items checked
- No console errors in Xcode
- No JS errors in WebView console
