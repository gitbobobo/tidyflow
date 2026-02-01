# Native Command Palette & Keybindings (Phase B-2)

## Goals
Implement a native Command Palette and Quick Open experience that works seamlessly with the Native Tabs system, providing keyboard-centric navigation and control.

## 1. Keybinding System

### Global Keybindings
These work anywhere in the app.

| Shortcut | Command | Scope | Action |
|---|---|---|---|
| `Cmd+Shift+P` | Show Command Palette | Global | Opens palette in "Command Mode" |
| `Cmd+P` | Quick Open | Global | Opens palette in "File Mode" |
| `Cmd+1` | Toggle Explorer | Global | Activates Explorer panel |
| `Cmd+2` | Toggle Search | Global | Activates Search panel |
| `Cmd+3` | Toggle Git | Global | Activates Git panel |
| `Cmd+R` | Reconnect | Global | Toggles connection state (mock/placeholder) |

### Workspace Keybindings
These require an active workspace. If no workspace is selected, they are disabled or ignored.

| Shortcut | Command | Scope | Action |
|---|---|---|---|
| `Cmd+T` | New Terminal Tab | Workspace | Creates a new terminal tab in active workspace |
| `Cmd+W` | Close Tab | Workspace | Closes the active tab |
| `Ctrl+Tab` | Next Tab | Workspace | Cycles to next tab |
| `Ctrl+Shift+Tab` | Previous Tab | Workspace | Cycles to previous tab |
| `Cmd+S` | Save | Workspace | Prints "(placeholder) saved" if editor is active |

## 2. Command Palette UI

### Architecture
- **Overlay**: A `ZStack` in `ContentView` places the palette above all other content.
- **Focus**: When opened, the palette's input field grabs focus.
- **Modes**:
  - `command`: Lists available commands.
  - `file`: Lists mock files (Quick Open).

### UI Components
- **Input Field**: Top text field for filtering.
- **List**: Scrollable list of results.
- **Selection**: Highlighted row controlled by Up/Down arrows.
- **Footer**: Keybinding hints (optional).

### Behavior
- **Filtering**:
  - **Commands**: Fuzzy/Contains match on Title.
  - **Files**: Fuzzy/Contains match on Path/Filename.
- **Navigation**: Up/Down arrows change selection.
- **Execution**: Enter runs the selected command or opens the file.
- **Dismiss**: Esc or clicking outside closes the palette.

## 3. Data Models

### Command Struct
```swift
struct Command: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let shortcut: String? // Display hint
    let action: (AppState) -> Void
    let scope: CommandScope
}

enum CommandScope {
    case global
    case workspace
}
```

### AppState Extensions
- `commandPalettePresented`: Bool
- `commandPaletteMode`: .command | .file
- `commandQuery`: String
- `paletteSelectionIndex`: Int
- `activeCommands`: Computed property returning filtered commands based on query and scope.

## 4. Implementation Details

### Views/Models.swift
- Add `Command`, `CommandScope`, `PaletteMode`.
- Extend `AppState` with palette state and helper methods (`addTerminalTab`, `addEditorTab`, etc.).

### Views/CommandPaletteView.swift
- Implements the visual overlay.
- Handles internal keyboard events (Up/Down/Enter/Esc) using `onKeyPress` (macOS 14+) or hidden button hacks for older versions (we'll target modern macOS).

### Views/KeybindingHandler.swift
- A `ViewModifier` or dedicated `View` that attaches `.keyboardShortcut` modifiers to the root view.
- Ensures global shortcuts are always available.

### Views/ContentView.swift
- Apply the KeybindingHandler.
- Add the CommandPalette overlay.

## 5. Mock Data (Quick Open)
- Dictionary mapping `workspaceKey` to `[String]` (file paths).
- Example: `["src/main.rs", "README.md", "Cargo.toml"]`.

## 6. Verification
- Use `scripts/native-command-palette-check.md` to verify all scenarios.
