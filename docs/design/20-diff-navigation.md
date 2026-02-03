# Diff Navigation Design

## Overview

This document describes the line navigation feature in the Diff Tab, allowing users to click on diff lines to jump to the corresponding location in the source file.

## Parsing Rules

### Unified Diff Format

The parser handles standard unified diff format:

```
diff --git a/file.txt b/file.txt
index abc123..def456 100644
--- a/file.txt
+++ b/file.txt
@@ -10,5 +10,7 @@ optional context
 context line
-removed line
+added line
 context line
```

### Hunk Header Parsing

Hunk headers follow the pattern: `@@ -oldStart,oldCount +newStart,newCount @@ optional`

- `oldStart`: Starting line number in the old file
- `newStart`: Starting line number in the new file
- Counts are optional (default to 1)

### Line Counting Algorithm

Within each hunk, maintain two counters:
- `currentOldLine`: Current line in old file
- `currentNewLine`: Current line in new file

Line type handling:
| First Char | Action | Clickable |
|------------|--------|-----------|
| ` ` (space) | oldLine++, newLine++ | Yes → newLine |
| `+` | newLine++ | Yes → newLine |
| `-` | oldLine++ | Yes → newLine (nearest) |
| `@@` | Reset counters from header | No |
| `---`, `+++`, `diff`, `index` | Skip | No |

### Non-Clickable Lines

- `diff --git` header
- `index` line
- `---` and `+++` file markers
- `new file mode` / `deleted file mode`
- `Binary files` marker
- `\ No newline at end of file`

## Jump Strategy

### Added Lines (`+`)
Jump to the exact line number in the new file where this line was added.

### Context Lines (` `)
Jump to the exact line number in the new file.

### Deleted Lines (`-`)
Since deleted lines don't exist in the new file, jump to the **nearest context position** (the current `newLine` value). This represents where the deletion occurred relative to surrounding context.

**Rationale**: The nearest context approach is intuitive because:
1. It shows where the deletion happened in the current file
2. The user can see the surrounding code that remains
3. It's consistent with how git blame handles deleted lines

### Deleted Files (`D` status)
- "Open file" button is disabled with tooltip "File has been deleted"
- Line clicks are disabled
- Status bar shows "File deleted - navigation disabled"

### Binary Files
- Navigation is disabled
- Content shows "Binary file diff not supported"

## UI Components

### Toolbar Buttons

1. **Open file** (`📄 Open file`)
   - Opens the file in Editor Tab without specifying a line
   - Disabled for deleted files

2. **Refresh** (`↻ Refresh`)
   - Reloads the diff from the server

### Line Click Behavior

1. User clicks a clickable diff line
2. System extracts `data-lineNew` and `data-path` from the element
3. If editor tab exists: switch to it and scroll
4. If editor tab doesn't exist: open file, then scroll after load
5. Highlight target line with yellow background for 2 seconds

### Status Bar

Shows contextual information:
- Default: "Click any line to jump to that location in the file"
- Truncated: "⚠️ Diff too large, truncated to 1MB | Click any line..."
- Deleted file: "File deleted - navigation disabled"

## Implementation Details

### Data Attributes

Each clickable line element has:
```html
<div class="diff-line diff-add"
     data-line-new="42"
     data-path="src/main.rs"
     data-clickable="true">
+    new code here
</div>
```

### Line Highlight

Uses CodeMirror's decoration system:
1. Create a `StateEffect` for highlight changes
2. Create a `StateField` to track highlight decorations
3. Apply line decoration with `.cm-highlight-line` class
4. Remove decoration after 2 seconds via `setTimeout`

### Pending Navigation

For files not yet open:
1. Store `{ filePath, lineNumber }` in `pendingLineNavigation`
2. Request file read from server
3. On `file_read_result`, check for pending navigation
4. If match, scroll to line after 50ms delay (ensures editor init)

## Edge Cases

### Large Diffs (>1MB)
- Diff is truncated server-side
- Warning shown in status bar
- Navigation still works for visible lines

### Empty Diffs
- Shows "No changes" message
- No clickable elements

### New Files (`A` status)
- All lines are additions (`+`)
- Full navigation support

### Renamed Files
- Navigation uses the new file path
- Works normally

## CSS Classes

| Class | Purpose |
|-------|---------|
| `.diff-line` | Base line styling |
| `.diff-line[data-clickable="true"]` | Cursor pointer, hover effect |
| `.diff-header` | Gray color for headers |
| `.diff-hunk` | Blue color, light background |
| `.diff-add` | Green color, light green background |
| `.diff-remove` | Red color, light red background |
| `.diff-meta` | Gray italic for special markers |
| `.cm-highlight-line` | Yellow background for target line |

## Future Enhancements

1. **Split diff view**: Side-by-side old/new comparison
2. **Virtual scrolling**: For very large diffs (>10K lines)
3. **Staged diff**: Show staged vs unstaged changes
4. **Inline blame**: Show commit info on hover
5. **Syntax highlighting**: Language-aware diff coloring
