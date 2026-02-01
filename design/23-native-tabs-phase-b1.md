# Design: Native Tabs Phase B-1 (Shell Only)

## Overview
This phase implements the native SwiftUI shell for tabs, managing tab state per workspace without implementing actual tab content (Editor/Terminal/Diff) or changing the underlying Rust/Web architecture.

## Goals
1.  **Native Tab Strip**: SwiftUI tab bar in the center area.
2.  **Workspace-scoped Tabs**: Each workspace has its own independent set of tabs.
3.  **State Management**: `AppState` holds the source of truth for tabs.
4.  **Placeholders**: Tab content is strictly placeholder views.

## Data Models (in `Models.swift`)

```swift
enum TabKind: String, Codable {
    case terminal
    case editor
    case diff
}

struct TabModel: Identifiable, Codable {
    let id: UUID
    var title: String
    let kind: TabKind
    let workspaceKey: String
    let payload: String // path, diffPath, etc.
}

// Map workspaceKey -> [TabModel]
typealias TabSet = [TabModel]

class AppState: ObservableObject {
    // ... existing properties ...
    @Published var workspaceTabs: [String: TabSet] = [:]
    @Published var activeTabIdByWorkspace: [String: UUID] = [:]
    
    // Actions
    func ensureDefaultTab(for workspaceKey: String)
    func closeTab(workspaceKey: String, tabId: UUID)
    func activateTab(workspaceKey: String, tabId: UUID)
}
```

## UI Components

### `TabStripView`
- Displays tabs for the current `selectedWorkspaceKey`.
- Horizontal `ScrollView` or `HStack`.
- Each tab shows: Icon (SF Symbol), Title, Close Button.
- Highlights active tab.
- Temporary Debug Buttons: `+T`, `+E`, `+D` to spawn tabs.

### `TabContentHostView`
- Observes `activeTabId`.
- Switches content based on `TabKind`.
- Renders Placeholders:
  - Terminal: "Terminal Placeholder"
  - Editor: "Editor Placeholder: <path>"
  - Diff: "Diff Placeholder: <path>"

### `CenterContentView` Layout
```swift
VStack(spacing: 0) {
    if hasSelectedWorkspace {
        TabStripView()
        Divider()
        TabContentHostView()
    } else {
        // Empty state (or existing WebView for Phase A compatibility if needed, 
        // but requirements say "Unselected workspace: no tabs, empty state")
        // We might keep the WebView at the bottom or hidden as per requirement B2:
        // "Can keep single WKWebView below or unused"
        // Decision: Put WebView in background ZStack or below TabHost for now to avoid breaking existing logic if any.
        // For B-1 strict compliance: "Tab strip + Content Host".
    }
}
```

## WebBridge Updates
- Add `openTerminal(workspaceKey)` -> Log only.
- Add `openFile(workspaceKey, path)` -> Log only.
- Add `openDiff(workspaceKey, path, mode)` -> Log only.

## Verification
- Manual check using `scripts/native-tabs-check.md`.
- Ensure workspace switching preserves tab state.
- Ensure closing active tab selects neighbor.
