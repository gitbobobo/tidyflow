# Native Tabs Phase B-1 Verification

## Setup
1. Build and run TidyFlow.
2. Ensure you are in the default view (Left sidebar, Center content, Right toolbar).

## Check List

### 1. Initial State
- [ ] Launch app.
- [ ] Verify "Default Workspace" is selected (from `Models.swift` init).
- [ ] Verify ONE tab exists: "Terminal" (auto-created by `ensureDefaultTab`).
- [ ] Verify Center Content shows "Terminal Placeholder".

### 2. Tab Creation (Debug Buttons)
- [ ] Click `+T` button in Tab Strip.
  - [ ] New "Term" tab appears.
  - [ ] New tab is active (highlighted).
  - [ ] Content shows "Terminal Placeholder".
- [ ] Click `+E` button.
  - [ ] New "Edit" tab appears.
  - [ ] Content shows "Editor Placeholder: main.rs".
- [ ] Click `+D` button.
  - [ ] New "Diff" tab appears.
  - [ ] Content shows "Diff Placeholder: main.rs (working/staged)".

### 3. Workspace Switching & Persistence
- [ ] Switch to "Project Alpha" (click in Left Sidebar).
  - [ ] Tab Strip should clear (or show default Terminal if it's first visit).
  - [ ] Verify "Terminal" tab is present (auto-created).
- [ ] Create 2 new tabs in "Project Alpha" (e.g., +E, +E).
- [ ] Switch back to "Default Workspace".
  - [ ] Verify previous tabs (Terminal, Term, Edit, Diff) are restored.
  - [ ] Verify active tab is preserved.
- [ ] Switch back to "Project Alpha".
  - [ ] Verify its tabs (Terminal, Edit, Edit) are restored.

### 4. Tab Closing Logic
- [ ] In "Default Workspace", select the middle tab.
- [ ] Click "x" on the active tab.
  - [ ] Tab disappears.
  - [ ] Adjacent tab becomes active.
- [ ] Close ALL tabs.
  - [ ] Last tab closed -> Tab Strip shows empty or just spacers? 
  - [ ] (Refinement: `ensureDefaultTab` is only called on init/select? If user closes all, it might be empty. This is acceptable for Phase B-1 shell).

### 5. Empty State
- [ ] (Optional) Modify `Models.swift` to set `selectedWorkspaceKey = nil` in init.
- [ ] Rerun app.
- [ ] Verify Center Content shows "No Workspace Selected".
- [ ] Verify no Tab Strip is visible.
