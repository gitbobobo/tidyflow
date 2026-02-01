# Native Command Palette & Keybindings Verification

## 1. Global Shortcuts
- [ ] Launch app.
- [ ] Ensure WebView has focus (click center area).
- [ ] Press `Cmd+Shift+P`: Command Palette should appear (Command Mode).
- [ ] Press `Esc`: Command Palette should close.
- [ ] Press `Cmd+P`: Command Palette should appear (File Mode).
- [ ] Press `Cmd+1`: Explorer panel should activate.
- [ ] Press `Cmd+2`: Search panel should activate.
- [ ] Press `Cmd+3`: Git panel should activate.
- [ ] Press `Cmd+R`: Connection status should toggle.

## 2. Command Palette Navigation
- [ ] Open Command Palette (`Cmd+Shift+P`).
- [ ] Type "toggle": List should filter.
- [ ] Use Up/Down arrows: Selection highlight should move.
- [ ] Press Enter on "Show Search": Search panel should activate and palette should close.
- [ ] Open Palette again. Click on a command: It should execute and close.

## 3. Quick Open (Mock)
- [ ] Select "Default Workspace".
- [ ] Press `Cmd+P`.
- [ ] Type "read": Should show `README.md`.
- [ ] Select `README.md` and press Enter: A new editor tab titled "README.md" should appear.

## 4. Workspace Scoped Commands
- [ ] Ensure "Default Workspace" is selected.
- [ ] Press `Cmd+T`: A new Terminal tab should appear.
- [ ] Press `Cmd+W`: The active tab should close.
- [ ] Open multiple tabs. Press `Ctrl+Tab`: Should cycle tabs.
- [ ] Press `Cmd+S`: Should print "(placeholder) saved" to console (check logs).

## 5. Scope Validation
- [ ] Deselect workspace (or select a new empty one if possible, or restart app and don't select).
- [ ] Open Command Palette (`Cmd+Shift+P`).
- [ ] Verify workspace-specific commands (e.g. "New Terminal") are NOT visible or disabled (implementation filters them out).
- [ ] Press `Cmd+T`: Should do nothing.
