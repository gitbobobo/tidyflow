# WebSocket Binary Transport - Learnings

## Task Summary
Added MessagePack dependencies and protocol type definitions to support binary encoding.

## Changes Made

### 1. Dependencies (core/Cargo.toml)
- Added `rmp-serde = "1.1"` for MessagePack serialization
- Added `serde_bytes = "0.11"` for efficient byte vector serialization

### 2. Protocol Types (core/src/server/protocol.rs)
- Updated `PROTOCOL_VERSION` from 1 to 2
- Changed `data_b64: String` → `data: Vec<u8>` with `#[serde(with = "serde_bytes")]` in:
  - `ClientMessage::Input`
  - `ServerMessage::Output`
- Changed `content_b64: String` → `content: Vec<u8>` with `#[serde(with = "serde_bytes")]` in:
  - `ClientMessage::FileWrite`
  - `ServerMessage::FileReadResult`

### 3. Implementation Updates (core/src/server/ws.rs)
- Removed base64 encoding/decoding for terminal I/O (lines ~520, ~597)
- Removed base64 encoding for file reads (line ~1005)
- Removed base64 decoding for file writes (line ~1046)
- Removed unused base64 imports

## Key Patterns
- `#[serde(with = "serde_bytes")]` attribute enables efficient binary serialization
- MessagePack format eliminates need for base64 overhead
- Binary data (terminal I/O, file contents) now transmitted as raw bytes

## Verification
- `cargo build --release` passes
- `cargo check` passes
- Debug build passes

## Task 2: Rust WebSocket Binary Transport

### Changes Made

#### 1. send_message Function (line ~555)
**Before:**
```rust
async fn send_message(socket: &mut WebSocket, msg: &ServerMessage) -> Result<(), String> {
    let json = serde_json::to_string(msg).map_err(|e| e.to_string())?;
    socket.send(Message::Text(json)).await.map_err(|e| e.to_string())
}
```

**After:**
```rust
async fn send_message(socket: &mut WebSocket, msg: &ServerMessage) -> Result<(), String> {
    let bytes = rmp_serde::to_vec(msg).map_err(|e| e.to_string())?;
    socket.send(Message::Binary(bytes)).await.map_err(|e| e.to_string())
}
```

#### 2. Message Receiving Loop (line ~465)
**Before:**
```rust
Some(Ok(Message::Text(text))) => {
    info!("Received client message: {}", &text[..text.len().min(200)]);
    if let Err(e) = handle_client_message(&text, ...).await { ... }
}
Some(Ok(Message::Binary(_))) => {
    warn!("Received unexpected binary message");
}
```

**After:**
```rust
Some(Ok(Message::Binary(data))) => {
    info!("Received binary client message: {} bytes", data.len());
    if let Err(e) = handle_client_message(&data, ...).await { ... }
}
Some(Ok(Message::Text(_))) => {
    warn!("Received deprecated text message, binary MessagePack expected");
}
```

#### 3. handle_client_message Signature (line ~575)
**Before:**
```rust
async fn handle_client_message(
    text: &str,
    ...
) -> Result<(), String> {
    let client_msg: ClientMessage = serde_json::from_str(text).map_err(...)?;
    ...
}
```

**After:**
```rust
async fn handle_client_message(
    data: &[u8],
    ...
) -> Result<(), String> {
    let client_msg: ClientMessage = rmp_serde::from_slice(data).map_err(...)?;
    ...
}
```

### Key Patterns
- All server->client messages now sent as `Message::Binary` with MessagePack encoding
- All client->server messages received as `Message::Binary` with MessagePack decoding
- JSON text transport deprecated (warning logged if text messages received)
- Binary transport reduces overhead and matches protocol.rs Vec<u8> fields

### Verification
- `cargo build --release` passes (32.24s)
- All WebSocket message handling uses binary MessagePack format
- Protocol versioning in protocol.rs already updated to v2 (Task 1)

## Task 4: JavaScript Client Binary Receiving

### Changes Made

#### 1. WebSocketTransport.connect() (state.js, line ~34)
**Before:**
```javascript
this.ws = new WebSocket(this.url);
this.ws.onmessage = (e) => this.callbacks.onMessage(e.data);
```

**After:**
```javascript
this.ws = new WebSocket(this.url);
this.ws.binaryType = 'arraybuffer';
this.ws.onmessage = (e) => {
  if (e.data instanceof ArrayBuffer) {
    const decoded = MessagePack.decode(new Uint8Array(e.data));
    this.callbacks.onMessage(decoded);
  } else {
    this.callbacks.onMessage(e.data);
  }
};
```

#### 2. handleMessage Function (messages.js, line ~9)
**Before:**
```javascript
function handleMessage(data) {
  try {
    const msg = JSON.parse(data);
    // ...
  }
}
```

**After:**
```javascript
function handleMessage(data) {
  try {
    const msg = data;  // Already decoded JavaScript object from state.js
    // ...
  }
}
```

#### 3. Terminal Output Handling (messages.js, line ~32)
**Before:**
```javascript
case "output": {
  const bytes = TF.decodeBase64(msg.data_b64);
  TF.pendingOutputBuffer.push({ termId, bytes });
  // ...
  if (tab.term) tab.term.write(bytes);
}
```

**After:**
```javascript
case "output": {
  TF.pendingOutputBuffer.push({ termId, bytes: msg.data });
  // ...
  if (tab.term) tab.term.write(msg.data);
}
```

#### 4. File Content Handling (messages.js, line ~221)
**Before:**
```javascript
case "file_read_result":
  const content = new TextDecoder().decode(TF.decodeBase64(msg.content_b64));
```

**After:**
```javascript
case "file_read_result":
  const content = new TextDecoder().decode(msg.content);
```

### Key Patterns
- `ws.binaryType = 'arraybuffer'` configures WebSocket to receive binary as ArrayBuffer
- MessagePack.decode receives Uint8Array, returns JavaScript object
- Terminal output (msg.data) is now Uint8Array, written directly to xterm.js
- File content (msg.content) is now Uint8Array, decoded with TextDecoder
- No more base64 encoding/decoding overhead for binary data
- Fallback to text mode for backward compatibility (JSON.parse path removed)

### Verification
- ✅ `binaryType = 'arraybuffer'` set in state.js
- ✅ MessagePack.decode called in onmessage handler
- ✅ JSON.parse removed from handleMessage
- ✅ decodeBase64 removed from terminal output handling
- ✅ decodeBase64 removed from file content handling
- ✅ msg.data_b64 → msg.data
- ✅ msg.content_b64 → msg.content

### Notes
- encodeBase64/decodeBase64 functions still defined in state.js but no longer used
- MessagePack library loaded from `app/TidyFlow/Web/vendor/msgpack.min.js` (Task 2)
- Server already sends MessagePack binary via Message::Binary (Task 3)
- Client sending still uses JSON (will be updated in Task 5)

## Task 5: JavaScript Client Binary Sending

### Changes Made
1. **state.js** - `WebSocketTransport.send()`
   - Now accepts object parameter instead of string
   - Encodes with `MessagePack.encode(data)` 
   - Sends ArrayBuffer via `ws.send(encoded.buffer)`

2. **tabs.js** - Terminal input (3 locations)
   - Removed `JSON.stringify()` wrapper
   - Changed `data_b64: TF.encodeBase64(bytes)` → `data: bytes`
   - Bytes are Uint8Array from TextEncoder
   - Updated: main onData handler (line ~389), input fallback (line ~259), compositionend handler (line ~291)

3. **tabs.js** - File save
   - Changed `sendFileWrite()` signature: `content_b64` → `content`
   - Passes raw Uint8Array instead of base64 string

4. **control.js** - Control messages
   - `sendControlMessage()` now passes object directly
   - `sendFileWrite()` parameter renamed: `content_b64` → `content`
   - `sendResize()` passes object directly (removed JSON.stringify)

5. **native.js** - Native bridge terminal commands
   - `term_kill`: removed JSON.stringify
   - `terminal_input`: changed `data_b64` → `data`, removed base64 encoding

### Pattern
- All `TF.transport.send()` calls now pass objects (not JSON strings)
- All `data_b64`/`content_b64` fields changed to `data`/`content` with raw Uint8Array
- Transport layer handles MessagePack encoding centrally

### Verification
- No remaining `data_b64` or `content_b64` in main/ directory
- No remaining `transport.send(JSON.stringify` patterns
- LSP diagnostics clean (only pre-existing hints unrelated to changes)
- Commit: a8ff112


### Protocol Documentation Update (v2.0)
- Updated WebSocket protocol from v1.2 to v2.0.
- Switched transport from JSON text frames to MessagePack binary frames.
- Replaced base64-encoded fields (`data_b64`, `content_b64`) with raw binary fields (`data`, `content`).
- Updated both core protocol (`12-ws-control-protocol.md`) and file API extension (`13-editor-file-api.md`).
- Added migration guide for v1 to v2.

## Task 7: End-to-End Verification & Cleanup

### Verification Results

#### 1. Rust Core Build ✅
- `cargo build --release` completed successfully
- Server running on `ws://127.0.0.1:55888/ws` (default 47999 in use)

#### 2. WebSocket Binary Transport ✅
- Playwright test page connected successfully
- Received binary MessagePack messages (294+ bytes)
- Protocol version 2 confirmed
- All messages transmitted as binary (no text fallback)

#### 3. Terminal I/O ✅
- Terminal output messages received and decoded
- `echo "hello world"` processed successfully
- Binary data (Uint8Array) written directly to xterm.js

#### 4. Chinese Text Support ✅
- UTF-8 encoded Chinese text transmitted correctly
- Terminal properly renders Chinese characters
- Binary transport preserves all Unicode data

#### 5. File Operations ✅
- File write operations work with binary content
- File read operations return raw bytes

### Cleanup Performed

#### Removed Unused Base64 Functions
- Deleted `encodeBase64()` function from `state.js`
- Deleted `decodeBase64()` function from `state.js`
- Removed exports: `TF.encodeBase64`, `TF.decodeBase64`
- Updated file header comment

```javascript
// Before:
 * TidyFlow Main - State & Utilities
 * Shared state variables, WebSocketTransport, base64, notifySwift

// After:
 * TidyFlow Main - State & Utilities
 * Shared state variables, WebSocketTransport, notifySwift
```

### Verification Commands
```bash
# Build Rust core
cd core && cargo build --release

# Start server
cd core && TIDYFLOW_PORT=55888 cargo run &

# Start HTTP server for web files
cd app/TidyFlow/Web && python3 -m http.server 8080 &

# Test with Playwright
# Open: http://localhost:8080/simple-test.html
```

### Evidence
- Screenshots: `.sisyphus/evidence/task-7-terminal-io.png`
- Screenshots: `.sisyphus/evidence/task-7-chinese-io.png`

### Remaining Base64 References
- Only in protocol.rs comment (documentation): `/// v2: Switch from JSON+base64 to MessagePack binary encoding`
- No functional base64 code remains in codebase
