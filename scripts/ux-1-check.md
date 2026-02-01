# UX-1 Verification Checklist

## Prerequisites
- [ ] Core process running (`cargo run` in core/)
- [ ] App built and launched

## Verification Steps

1. [ ] **Toolbar**: No workspace picker dropdown visible
2. [ ] **Toolbar**: + button visible, shows "Add Project" tooltip
3. [ ] **Sidebar**: Shows "Projects" header with + button
4. [ ] **Sidebar**: Default Project visible with workspaces as children
5. [ ] **Sidebar**: Project row is collapsible (click chevron)
6. [ ] **Selection**: Click workspace -> center shows tabs area
7. [ ] **Selection**: Cmd+T creates new terminal tab
8. [ ] **Add Project**: Click + -> sheet opens with folder picker
9. [ ] **Add Project**: Select folder -> name auto-fills
10. [ ] **Add Project**: Click Import -> project appears in sidebar
11. [ ] **WebView**: No duplicate sidebar/tabbar/tools visible
12. [ ] **Console**: "[TidyFlow] Renderer-only mode enabled" logged

## Known Limitations (UX-1)
- Project import is local mock (no Core protocol yet)
- Workspace list is static (no Core list_workspaces yet)
- No "New Workspace" entry point yet
