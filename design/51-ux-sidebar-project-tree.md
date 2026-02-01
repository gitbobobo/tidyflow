# UX-1: Sidebar Project Tree Design

## Overview
Replace flat workspace list with hierarchical Project > Workspace tree structure.

## Data Model

```swift
struct WorkspaceModel: Identifiable {
    var id: String { name }
    let name: String
    var status: String?  // e.g., "running", "stopped"
}

struct ProjectModel: Identifiable {
    let id: UUID
    var name: String
    var path: String?
    var workspaces: [WorkspaceModel]
    var isExpanded: Bool = true
}
```

## AppState Extensions

```swift
@Published var projects: [ProjectModel] = []
@Published var selectedProjectId: UUID?
@Published var addProjectSheetPresented: Bool = false

func selectWorkspace(projectId: UUID, workspaceName: String)
func refreshProjectsAndWorkspaces()
```

## UI Components

### ProjectsSidebarView
- Header: "Projects" + Add button (+)
- Empty state: Icon + "No Projects" + "Add Project" button
- Project list: Collapsible DisclosureGroup per project
  - Project row: folder icon + name + workspace count badge
  - Workspace rows: grid icon + name + optional status

### AddProjectSheet
- File importer for folder selection
- Project name text field (defaults to folder name)
- Import button (creates local mock project for UX-1)

## Interaction Flow

1. User clicks + in toolbar or sidebar header
2. AddProjectSheet opens
3. User selects folder, confirms name
4. Project added to list, auto-expanded
5. Default workspace auto-selected
6. Tabs/editor/terminal become available

## State Transitions

| State | Sidebar Shows | Center Shows |
|-------|---------------|--------------|
| No projects | Empty state | "Add a project" |
| Projects, no selection | Project tree | "Select a workspace" |
| Workspace selected | Project tree (highlighted) | Tabs + content |

## Web Renderer-Only Mode

When Native Shell is active:
- `body.renderer-only` class hides: #left-sidebar, #right-panel, #tab-bar, .resize-handle-v
- Web only renders: terminal, editor, diff content
- Native Shell controls: sidebar, toolbar, tabs, right tools
