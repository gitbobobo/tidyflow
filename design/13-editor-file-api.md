# Editor File API Protocol (v1.3)

## Overview

Extension to WebSocket protocol v1.2 for file operations within workspace boundaries.

## Design Decisions

### Editor Choice: CodeMirror 6
- Lighter footprint (~200KB vs Monaco's ~2MB)
- Modular architecture, can vendor as single bundle
- Better for embedding in WebView
- Built-in UTF-8 text editing support

### Transport: WebSocket Extension
- Reuse existing WebSocket connection (no new HTTP server)
- Consistent with terminal protocol
- Single connection for all workspace operations

## Protocol Messages

### Client → Server

#### FileList
List files in workspace root directory.
```json
{
  "type": "file_list",
  "project": "string",
  "workspace": "string",
  "path": "string (optional, relative to workspace root, default: '.')"
}
```

#### FileRead
Read file content.
```json
{
  "type": "file_read",
  "project": "string",
  "workspace": "string",
  "path": "string (relative to workspace root)"
}
```

#### FileWrite
Write file content.
```json
{
  "type": "file_write",
  "project": "string",
  "workspace": "string",
  "path": "string (relative to workspace root)",
  "content_b64": "string (base64 encoded UTF-8 content)"
}
```

### Server → Client

#### FileListResult
```json
{
  "type": "file_list_result",
  "project": "string",
  "workspace": "string",
  "path": "string",
  "items": [
    {
      "name": "string",
      "is_dir": "boolean",
      "size": "number (bytes, 0 for directories)"
    }
  ]
}
```

#### FileReadResult
```json
{
  "type": "file_read_result",
  "project": "string",
  "workspace": "string",
  "path": "string",
  "content_b64": "string (base64 encoded)",
  "size": "number"
}
```

#### FileWriteResult
```json
{
  "type": "file_write_result",
  "project": "string",
  "workspace": "string",
  "path": "string",
  "success": "boolean",
  "size": "number (bytes written)"
}
```

#### Error (existing, extended)
```json
{
  "type": "error",
  "code": "string",
  "message": "string"
}
```

Error codes for file operations:
- `file_not_found` - File does not exist
- `file_too_large` - File exceeds 1MB limit
- `path_escape` - Path attempts to escape workspace root
- `io_error` - General I/O error
- `invalid_utf8` - File is not valid UTF-8

## Security Constraints

### Path Safety
1. All paths are relative to workspace root
2. Path normalization: resolve `.` and `..` components
3. Reject paths that escape workspace root after normalization
4. No symlink following outside workspace

### Size Limits
- Maximum file size: 1MB (1,048,576 bytes)
- Maximum path length: 4096 characters

### Content Encoding
- All file content is base64 encoded for transport
- Only UTF-8 text files supported
- Binary files will fail with `invalid_utf8` error

## Implementation Notes

### Rust Core (file_api.rs)
- Path canonicalization with workspace root check
- Atomic writes: write to temp file, then rename
- Serial execution (no concurrent file writes)

### Frontend (editor.js)
- CodeMirror 6 with basic setup
- File list panel (flat list, no tree)
- Single file editing (no tabs)
- Save status indicator

## Capabilities

Add to v1_capabilities():
- `file_operations` - File list/read/write support
