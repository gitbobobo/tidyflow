# How to Run Native Shell (Phase A)

## Running via Command Line
The easiest way to build and launch the app is using the existing script:

```bash
./scripts/run-app.sh
```

This will:
1.  Start the Rust core server (if not running).
2.  Build the macOS App (TidyFlow.app).
3.  Launch the App.

## Running via Xcode
1.  Open `app/TidyFlow.xcodeproj` in Xcode.
2.  **IMPORTANT**: Add the newly created files to the `TidyFlow` target:
    - Right-click `TidyFlow` group -> "Add Files to TidyFlow..."
    - Select `app/TidyFlow/Views` and `app/TidyFlow/WebView` folders.
    - Ensure "Create groups" is selected and "TidyFlow" target is checked.
3.  Select the `TidyFlow` scheme.
4.  Press `Cmd + R` to run.

## Phase A Acceptance Criteria
1.  **Launch**: App starts without crashing.
2.  **Layout**: 3-Column layout is visible (Sidebar, Content, Right Panel).
3.  **Sidebar**:
    - Shows "Workspaces" and "Projects" sections.
    - Can click items (highlight changes).
4.  **Content**:
    - Shows `WKWebView` (loading existing Web resources or placeholder).
    - Shows "Selected workspace: [key]" overlay when a workspace is selected in sidebar.
5.  **Right Panel**:
    - Shows 3 icons (Folder, Search, Git).
    - Clicking icons toggles the active tool and updates the header text ("Explorer Panel", etc.).
6.  **Toolbar**:
    - Shows "Disconnected" (Red dot) by default.
    - Clicking the refresh icon toggles to "Connected" (Green dot).
    - "Project" dropdown is clickable and lists mock projects.
7.  **Console**:
    - No excessive log spam.
    - Clicking buttons prints clear logs (e.g., "[WebBridge] Sending event...").

## Troubleshooting
- If Web content is blank: Ensure `app/TidyFlow/Web` folder is correctly added to the Xcode project resources (Copy Bundle Resources).
- If Build fails: Clean build folder (`Cmd + Shift + K` in Xcode) and retry.
