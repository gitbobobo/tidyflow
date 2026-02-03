# Phase C2-2b-1: Native Split Diff View (Minimum Viable)

## Overview

This phase adds a side-by-side (split) diff view to the native diff viewer, complementing the existing unified view. The implementation is minimal and functional, without advanced alignment algorithms.

## Data Structures

### DiffViewMode
```swift
enum DiffViewMode: String, Codable {
    case unified  // Single column, traditional unified diff
    case split    // Side-by-side, left=old, right=new
}
```

### SplitCell
```swift
struct SplitCell {
    let lineNumber: Int?
    let text: String
    let kind: DiffLineKind
    var isNavigable: Bool  // computed
}
```

### SplitRowKind
```swift
enum SplitRowKind {
    case header  // Full-width header row
    case hunk    // Full-width hunk header row
    case code    // Left/right code columns
}
```

### SplitRow
```swift
struct SplitRow: Identifiable {
    let id: Int
    let rowKind: SplitRowKind
    let left: SplitCell?
    let right: SplitCell?
    let fullText: String?  // For header/hunk rows
}
```

## Conversion Rules (SplitBuilder)

| Unified Line Kind | Left Column | Right Column |
|-------------------|-------------|--------------|
| header | - | - | (full-width row) |
| hunk | - | - | (full-width row) |
| context | oldLineNumber + text | newLineNumber + text |
| add (+) | empty | newLineNumber + text |
| del (-) | oldLineNumber + text | empty |

**Note:** This simple algorithm does NOT align corresponding add/del pairs. Each line becomes its own row.

## UI Components

### NativeDiffToolbar
- **Unified/Split** segmented picker (left)
- **Working/Staged** segmented picker (middle)
- **Refresh** button
- Split picker disabled when: binary file OR >5000 lines

### SplitRowView
- Header/hunk: full-width single row
- Code: two equal-width columns with vertical divider

### SplitCellView
- Line number column (40px)
- Prefix indicator (+/-/space)
- Text content (monospaced)
- Hover highlight
- Click to navigate

## State Management

### TabModel Extension
```swift
var diffViewMode: String?  // "unified" or "split"
```

### AppState Extensions
```swift
var activeDiffViewMode: DiffViewMode
func setActiveDiffViewMode(_ mode: DiffViewMode)
```

## Navigation Behavior

| Click Location | Action |
|----------------|--------|
| Right column (context/+) | Jump to newLineNumber |
| Left column (-) | Jump to nearest newLineNumber (stored in row) |
| Header/hunk | No action |
| Deleted file | Disabled (tooltip explains) |

## Edge Cases

1. **Binary files**: Split toggle disabled, shows "Binary file" tooltip
2. **Large diffs (>5000 lines)**: Split toggle disabled, auto-fallback to unified
3. **Deleted files**: Navigation disabled, tooltip explains
4. **Empty cells**: Shown with subtle gray background

## Limitations (This Phase)

1. **No alignment**: Add/del pairs are NOT aligned side-by-side
2. **No scroll sync**: Not needed (rows are naturally aligned)
3. **No virtual scrolling**: Uses LazyVStack (sufficient for <5000 lines)
4. **No word-level diff**: Only line-level highlighting

## Next Phase (C2-2b-2)

1. **Smart alignment algorithm**: Match corresponding add/del pairs
2. **Performance optimization**: Virtual scrolling for large diffs
3. **Word-level diff**: Highlight changed words within lines
4. **Configurable threshold**: User-adjustable line limit for split view

## Files Modified

- `app/TidyFlow/Networking/ProtocolModels.swift` - Added SplitRow, SplitCell, SplitBuilder
- `app/TidyFlow/Views/NativeDiffView.swift` - Added SplitRowView, SplitCellView, updated toolbar
- `app/TidyFlow/Views/Models.swift` - Added diffViewMode to TabModel, AppState helpers
- `app/TidyFlow/Views/TabContentHostView.swift` - Added currentViewMode state and handler
