# TidyFlow Protocol Schema & Editor Formatting Implementation Guide

## Executive Summary

This document consolidates the protocol schema, testing patterns, and implementation guidelines for implementing editor formatting features in TidyFlow. The protocol is **v10**, using **MessagePack binary encoding** with **domain/action envelope** routing.

---

## 1. PROTOCOL ARCHITECTURE OVERVIEW

### 1.1 Transport Layer
- **Real-time/Push Channel**: WebSocket (`/ws`) - MessagePack binary encoding
- **Read Channel**: HTTP (`/api/v1/*`) - JSON encoding
- **Local Auth Management**: HTTP (`/auth/keys`, loopback only) - JSON encoding
- **Default Bind Address**: `127.0.0.1:47999`
- **Protocol Version**: `PROTOCOL_VERSION = 10` (defined in `core/src/server/protocol/mod.rs`)

### 1.2 Message Model (v10 Envelope, v6 Semantics)

**Client Request**:
```rust
ClientEnvelopeV6 {
    request_id,
    domain,
    action,
    payload,
    client_ts
}
```

**Server Response/Event**:
```rust
ServerEnvelopeV6 {
    request_id?,
    seq,
    domain,
    action,
    kind,        // "result" | "event" | "error"
    payload,
    server_ts
}
```

### 1.3 Core Bootstrap (stdout)
Core outputs: `TIDYFLOW_BOOTSTRAP {json}` containing:
- `port`
- `bind_addr`
- `fixed_port`
- `remote_access_enabled`
- `protocol_version`
- `core_version`

---

## 2. PROTOCOL SCHEMA FILES STRUCTURE

### Location: `/schema/protocol/v10/`

**Files**:
1. **`domains.yaml`** - Authority source for domain/action routing rules
2. **`action_rules.csv`** - Machine-readable action→domain mapping (exact/prefix/contains)
3. **`README.md`** - Human-readable protocol documentation

### 2.1 Schema Definition Example

From `domains.yaml`:
```yaml
protocol_version: 10

domains:
  - id: system
    action_rule: exact("ping")
    http_read_endpoints:
      - GET /api/v1/system/snapshot
    observability_fields:
      perf_metrics:
        description: "统一性能指标快照"
        scope: global
        fields:
          - ws_task_broadcast_lag_total
          - ws_outbound_loop_tick
          - ...

  - id: file
    action_rule: prefix("file_") | prefix("watch_")
    http_read_endpoints:
      - GET /api/v1/projects/:project/workspaces/:workspace/files
      - GET /api/v1/projects/:project/workspaces/:workspace/files/index
      - GET /api/v1/projects/:project/workspaces/:workspace/files/content
    ws_read_via_http_required:
      - file_list
      - file_index
      - file_read
    required_boundary_fields:
      - project
      - workspace
```

### 2.2 Action Routing Rules

From `action_rules.csv` (excerpt):
```csv
# kind,domain,value
exact,system,ping
prefix,terminal,term_
exact,terminal,spawn_terminal
prefix,file,file_
prefix,git,git_
prefix,ai,ai_
prefix,evolution,evo_
prefix,health,health_
```

---

## 3. CORE PROTOCOL DOMAINS

### 3.1 System Domain
- **Actions**: `ping`
- **HTTP Read**: `GET /api/v1/system/snapshot`
- **Fields**:
  - `perf_metrics`: Global performance counters (WS latency, broadcast counts, terminal cleanup)
  - `log_context`: Log file path, retention days, perf logging flag
  - `performance_observability`: Full-stack latency metrics (WI-001 v1.46+)
  - `cache_metrics`: Per-workspace file/Git cache hit/miss/rebuild/eviction counts
  - `health_incidents`: System health exceptions list
  - `workspace_items`: All workspace states

### 3.2 Terminal Domain
- **Action Rule**: `prefix("term_")` | `one_of("spawn_terminal","kill_terminal","input","resize")`
- **HTTP Read**: `GET /api/v1/terminals`
- **WS Write Actions**: `term_create`, `term_input`, `term_close`
- **Lifecycle Phases**: `idle` → `entering` → `active` / `recovering` / `recovery_failed`
- **Recovery State** (v1.46+): Persistent recovery metadata for process restart

### 3.3 File Domain
- **Action Rule**: `prefix("file_")` | `prefix("watch_")`
- **HTTP Read**: 
  - `GET /api/v1/projects/:project/workspaces/:workspace/files`
  - `GET /api/v1/projects/:project/workspaces/:workspace/files/index`
  - `GET /api/v1/projects/:project/workspaces/:workspace/files/content`
  - `GET /api/v1/projects/:project/workspaces/:workspace/files/search?query=...`
- **WS Events**: `file_changed` (FileChangeKind: created/modified/removed/renamed)
- **FileWorkspacePhase** (state machine):
  - `idle` → `indexing` → `watching` / `degraded` → `error` → `recovering`

### 3.4 Git Domain
- **Action Rule**: `prefix("git_")` | `one_of("cancel_ai_task")`
- **HTTP Read**:
  - `GET /api/v1/projects/:project/workspaces/:workspace/git/status`
  - `GET /api/v1/projects/:project/workspaces/:workspace/git/diff`
  - `GET /api/v1/projects/:project/workspaces/:workspace/git/branches`
  - `GET /api/v1/projects/:project/workspaces/:workspace/git/conflicts/detail`
- **v1.40 Conflict Wizard**:
  - `git_conflict_detail`: Returns base_content, ours_content, theirs_content, current_content
  - `git_conflict_accept_ours/theirs/both`: Resolution actions
  - `git_conflict_mark_resolved`: Mark file as resolved
  - Context isolation: `workspace` vs `integration`

### 3.5 AI Domain
- **Action Rule**: `prefix("ai_")`
- **HTTP Read**:
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/sessions`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/sessions/:session_id/messages`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/slash-commands`
  - `GET /api/v1/projects/:project/workspaces/:workspace/ai/:ai_tool/session-config-options`
- **WS Subscribe Actions**: `ai_session_subscribe`, `ai_session_unsubscribe`
- **WS Stream Events**: `ai_session_messages_update`, `ai_chat_done`, `ai_chat_error`
- **Session Key Format** (v7.1): `{project}::{workspace}::{ai_tool}::{session_id}`
- **v1.42 Route Decision** (ai_chat_done/ai_chat_error):
  - New fields: `route_decision`, `budget_status`
  - selected_by: `explicit` | `task_type_policy` | `selection_hint` | `default`

### 3.6 Evolution Domain
- **Action Rule**: `prefix("evo_")`
- **HTTP Read**:
  - `GET /api/v1/evolution/snapshot`
  - `GET /api/v1/evolution/projects/:project/workspaces/:workspace/cycle-history`
- **WS Stream Events**: `evo_cycle_updated`, `evo_workspace_status`, `evo_error`
- **v1.47 Coordination**: New fields `coordination_state`, `coordination_reason`, `coordination_peer_workspace`, `coordination_queue_index`

### 3.7 Health Domain (v1.41)
- **Action Rule**: `prefix("health_")`
- **Actions**:
  - `health_snapshot`: Core → Client (system health incidents)
  - `health_report`: Client → Core (client health report)
  - `health_repair`: Client → Core (request repair action)
  - `health_repair_result`: Core → Client (repair execution result)
- **Repair Actions**: `invalidate_workspace_cache`, `rebuild_workspace_cache`, `restore_subscriptions`

---

## 4. MULTI-WORKSPACE BOUNDARY CONTRACT

### Critical: All responses and events MUST carry workspace context fields

**Required Boundary Fields**:
```json
{
  "project": "string (mandatory)",
  "workspace": "string (mandatory)",
  "session_id": "string (conditional for AI)",
  "cycle_id": "string (conditional for Evolution)"
}
```

**Client Consumption Rules**:
1. **MUST** route by `(project, workspace)` tuple, NOT workspace name alone
2. Same-named workspaces in different projects are **completely independent**
3. HTTP failures only affect the currently active workspace, not background workspaces
4. WS stream events from other workspaces must NOT override current workspace UI state

**Example Context Key**:
```swift
let globalKey = "\(project):\(workspace)"  // "my-proj:feature-x"
```

---

## 5. HTTP/WS TRANSMISSION BOUNDARY

### 5.1 WS Read Actions REMOVED (must use HTTP)

All these WS actions now return `error { code: "read_via_http_required" }`:

**Project/Settings/Terminal**:
- `list_projects`, `list_workspaces`, `list_tasks`, `list_templates`, `export_template`
- `get_client_settings`
- `term_list`

**File**:
- `file_list`, `file_index`, `file_read`, `file_content_search`

**Git**:
- `git_status`, `git_diff`, `git_branches`, `git_log`, `git_show`, `git_op_status`
- `git_conflict_detail`

**AI**:
- `ai_session_list`, `ai_session_messages`, `ai_session_status`
- `ai_provider_list`, `ai_agent_list`, `ai_slash_commands`

**Evolution**:
- `evo_get_snapshot`, `evo_get_agent_profile`, `evo_list_cycle_history`

### 5.2 WS-Only Actions (no HTTP equivalent)
- `ai_session_subscribe`, `ai_session_unsubscribe`
- All write operations (mutations)

### 5.3 HTTP Snapshot Fallback Semantics
- HTTP failure is keyed by `(project, workspace)`
- Only current workspace failure clears UI state
- Background workspace failures do NOT affect current workspace

---

## 6. PROTOCOL CONSISTENCY CHECK COMMANDS

From `scripts/tidyflow`:

```bash
./scripts/tidyflow check
```

Runs these checks:
1. **Protocol Consistency**: `check_protocol_consistency.sh`
2. **Schema Sync**: `check_protocol_schema_sync.sh`
3. **Code Generation Sync**: `gen_protocol_action_table.sh --check`
4. **Swift Rules Sync**: `gen_protocol_action_swift_rules.sh --check`
5. **Action Sync**: `check_protocol_action_sync.sh`
6. **Version Consistency**: `check_version_consistency.sh`

**What they verify**:
- `domains.yaml` protocol_version == `core/src/server/protocol/mod.rs` PROTOCOL_VERSION
- Domain set in `domains.yaml` == routing set in `core/src/server/ws/dispatch.rs`
- `app/TidyFlow/Networking/WSClient+Send.swift` rules cover all domains
- `action_rules.csv` matches Core/App/Web action rules
- Generated tables are in sync (not hand-edited)

---

## 7. TESTING PATTERNS

### 7.1 Core Protocol Testing Pattern

**Location**: `core/tests/protocol_v1.rs`

```rust
//! Protocol v7 Integration Tests
//! Tests the WebSocket control plane protocol (v7: MessagePack binary encoding)

struct ServerGuard {
    child: Option<Child>,
    port: u16,
}

impl ServerGuard {
    /// Starts server and waits for TIDYFLOW_BOOTSTRAP signal
    fn start() -> Result<Self, String> {
        let port = next_test_port();
        let bin_path = find_binary("tidyflow-core"); // release or debug
        
        let mut child = Command::new(&bin_path)
            .args(["serve", "--port", &port.to_string()])
            .env("TIDYFLOW_DEV", "1")
            .env_remove("TIDYFLOW_WS_TOKEN")
            .stdout(Stdio::piped())
            .spawn()?;
        
        // Read stdout, wait for TIDYFLOW_BOOTSTRAP line
        // Parse JSON to verify port and protocol_version
        // Timeout: 10 seconds
    }
}

#[tokio::test]
async fn test_protocol_envelope_v6() {
    let server = ServerGuard::start()?;
    let (ws_stream, _) = connect_async(format!("ws://127.0.0.1:{}/ws", server.port()))
        .await?;
    
    // Send ClientEnvelopeV6
    let request = json!({
        "request_id": 1,
        "domain": "system",
        "action": "ping",
        "payload": {},
        "client_ts": 1000
    });
    
    // Pack to MessagePack binary
    let msgpack_data = serde_json::to_vec(&request)?;
    ws_stream.send(Message::Binary(msgpack_data)).await?;
    
    // Receive ServerEnvelopeV6
    let msg = ws_stream.next().await;
    // Verify: request_id matches, kind="result", action="ping"
}
```

**Test Structure**:
1. Launch Core server with dynamic port allocation
2. Wait for `TIDYFLOW_BOOTSTRAP` stdout signal
3. Connect WebSocket client
4. Send/receive MessagePack-encoded envelopes
5. Verify domain/action routing
6. Clean up (ServerGuard drop kills process)

### 7.2 Apple/Shared Protocol Testing Pattern

**Location**: `app/TidyFlowTests/PerformanceObservabilitySemanticsTests.swift`

```swift
import XCTest
@testable import TidyFlow

/// Performance observability shared model semantics test (WI-006)
/// 
/// Coverage:
/// - LatencyMetricWindow / MemoryUsageSnapshot / CoreRuntimeMemorySnapshot JSON decode
/// - ClientPerformanceReport decode & client_instance_id field mapping
/// - WorkspacePerformanceSnapshot decode & (project, workspace) isolation key
/// - PerformanceObservabilitySnapshot complete structure decode
/// - Multi-instance client_instance_id isolation
/// - snake_case ↔ camelCase mapping correctness

final class PerformanceObservabilitySemanticsTests: XCTestCase {
    
    func testLatencyMetricWindow_decodesAllFields() throws {
        let json = """
        {
            "last_ms": 42,
            "avg_ms": 35,
            "p95_ms": 80,
            "max_ms": 120,
            "sample_count": 10,
            "window_size": 128
        }
        """.utf8Data
        
        let window = try JSONDecoder().decode(LatencyMetricWindow.self, from: json)
        XCTAssertEqual(window.lastMs, 42)
        XCTAssertEqual(window.avgMs, 35)
        XCTAssertEqual(window.p95Ms, 80)
        XCTAssertEqual(window.maxMs, 120)
        XCTAssertEqual(window.sampleCount, 10)
        XCTAssertEqual(window.windowSize, 128)
    }
    
    func testPerformanceObservabilitySnapshot_multiWorkspaceIsolation() throws {
        let json = """
        {
            "workspace_metrics": [
                {
                    "project": "proj-a",
                    "workspace": "default",
                    "file_indexing_latency": {...}
                },
                {
                    "project": "proj-a",
                    "workspace": "feature-x",
                    "file_indexing_latency": {...}
                },
                {
                    "project": "proj-b",
                    "workspace": "default",
                    "file_indexing_latency": {...}
                }
            ]
        }
        """.utf8Data
        
        let snap = try JSONDecoder().decode(PerformanceObservabilitySnapshot.self, from: json)
        
        // Each workspace must use (project, workspace) tuple as cache key
        for metric in snap.workspaceMetrics {
            let globalKey = "\(metric.project):\(metric.workspace)"
            // NOT just metric.workspace alone
            cacheStore[globalKey] = metric  // Correct
        }
    }
}
```

**Test Structure**:
1. Define test JSON payloads with protocol field names (snake_case)
2. Decode using Swift's JSONDecoder (auto camelCase mapping)
3. Assert field values match expected
4. Test boundary field handling (project, workspace, session_id, cycle_id)
5. Test multi-workspace isolation (same-named workspaces are distinct)
6. Test optional field presence/absence

### 7.3 Shared Handler Testing Pattern

**Test Files to Reference**:
- `SharedProtocolModelsTests.swift` - Protocol DTO decoding
- `AIChatProtocolModelsTests.swift` - AI domain messages
- `WorkspaceSharedStateSemanticsTests` - Multi-workspace isolation
- `TerminalWorkspaceIsolationTests` - Terminal per-workspace lifecycle

---

## 8. EDITOR FORMATTING PROTOCOL (Design Pattern)

### 8.1 Proposed Domain: `format`

**Action Rule Pattern**:
```yaml
- id: format
  action_rule: prefix("format_")
  http_write_endpoints: []
  ws_write_actions:
    - format_document
    - format_range
    - format_selection
  ws_stream_events:
    - format_result
    - format_error
    - format_progress
  required_boundary_fields:
    - project
    - workspace
```

### 8.2 Protocol Message Structure

**Client Request** (WS):
```json
{
  "domain": "format",
  "action": "format_document",
  "payload": {
    "project_name": "my-project",
    "workspace_name": "default",
    "path": "src/main.ts",
    "language": "typescript",
    "content": "function  foo( ){  return 42;  }",
    "range": null,
    "options": {
      "indent_size": 2,
      "use_tabs": false
    }
  }
}
```

**Server Response** (WS):
```json
{
  "domain": "format",
  "action": "format_result",
  "kind": "result",
  "payload": {
    "project": "my-project",
    "workspace": "default",
    "path": "src/main.ts",
    "formatted_content": "function foo() {\n  return 42;\n}",
    "changes": [
      {
        "range": {"start": {"line": 0, "character": 8}, "end": {"line": 0, "character": 11}},
        "new_text": ""
      }
    ],
    "duration_ms": 12
  }
}
```

### 8.3 Implementation Checklist

**Core Changes**:
- [ ] Add `format` domain to `schema/protocol/v10/domains.yaml`
- [ ] Add action rules to `schema/protocol/v10/action_rules.csv`
- [ ] Implement Core handler in `core/src/server/handlers/format.rs`
- [ ] Wire handler in `core/src/server/ws/dispatch.rs`
- [ ] Add protocol DTOs in `core/src/server/protocol/mod.rs`
- [ ] Run `./scripts/tidyflow check` to verify consistency

**macOS Changes**:
- [ ] Add Swift protocol models in `app/TidyFlowShared/Protocol/FormattingProtocolModels.swift`
- [ ] Implement WS send in `app/TidyFlow/Networking/WSClient+Send.swift`
- [ ] Implement message handler in `app/TidyFlow/Networking/WSClient+MessageHandlers.swift`
- [ ] Add tests in `app/TidyFlowTests/FormattingProtocolTests.swift`

**iOS Changes**:
- [ ] Reuse shared protocol models from TidyFlowShared
- [ ] Implement WS send in iOS WSClient adapter
- [ ] Implement message handler in iOS AppState

**Testing**:
- [ ] Core integration tests in `core/tests/protocol_v1.rs`
- [ ] Shared model tests in `app/TidyFlowTests/FormattingProtocolTests.swift`
- [ ] Multi-workspace isolation tests
- [ ] Error handling tests (file not found, unsupported language, etc.)

---

## 9. KEY FILES REFERENCE

### Schema & Documentation
- `schema/protocol/v10/domains.yaml` - **Authority source** for protocol domains
- `schema/protocol/v10/action_rules.csv` - Action→domain mapping
- `schema/protocol/v10/README.md` - Human-readable documentation
- `docs/PROTOCOL.md` - **COMPREHENSIVE** protocol specification (2062 lines)

### Core Protocol Implementation
- `core/src/server/protocol/mod.rs` - Protocol version & DTO definitions
- `core/src/server/ws/dispatch.rs` - Domain/action routing
- `core/src/server/handlers/` - Per-domain handler implementations
- `core/tests/protocol_v1.rs` - **Protocol integration tests**

### macOS/iOS Shared
- `app/TidyFlowShared/Protocol/ProtocolModels.swift` - Shared DTOs
- `app/TidyFlowShared/Protocol/AIChatProtocolModels.swift` - AI domain models
- `app/TidyFlowShared/Protocol/SystemHealthModels.swift` - Health domain models

### macOS App
- `app/TidyFlow/Networking/WSClient+Send.swift` - **Domain routing logic**
- `app/TidyFlow/Networking/WSClient+MessageHandlers.swift` - Event handlers
- `app/TidyFlowTests/` - **Test patterns** for shared semantics

### Consistency Checks
- `scripts/tools/check_protocol_consistency.sh`
- `scripts/tools/check_protocol_schema_sync.sh`
- `scripts/tools/gen_protocol_action_table.sh`
- `scripts/tools/gen_protocol_action_swift_rules.sh`

---

## 10. ERROR CONTRACT

### Standard Error Response

```json
{
  "code": "file_not_found",
  "message": "File 'src/main.ts' not found in workspace 'default'",
  "project": "my-project",
  "workspace": "default",
  "session_id": null,
  "cycle_id": null
}
```

**Error Codes for Formatting Domain**:
- `file_not_found` - Specified file doesn't exist
- `language_not_supported` - Language formatter unavailable
- `formatting_error` - Formatter execution failed
- `workspace_not_found` - Workspace doesn't exist
- `project_not_found` - Project doesn't exist
- `internal_error` - Core internal error

**Client Consumption**:
- State transitions **MUST** depend on `code`, never on `message` text
- Multi-workspace: filter by `project` + `workspace` fields
- macOS/iOS must exhibit identical core behavior for same error code

---

## 11. QUICK START COMMANDS

```bash
# Run all protocol consistency checks
./scripts/tidyflow check

# Run Core protocol tests
./scripts/tidyflow test

# Run Core and Apple tests
./scripts/tidyflow apple-regression

# View Core protocol test file
less core/tests/protocol_v1.rs

# View shared protocol models
less app/TidyFlowTests/PerformanceObservabilitySemanticsTests.swift

# Read comprehensive protocol documentation
less docs/PROTOCOL.md

# Check specific domain routes
grep -A 20 "id: format" schema/protocol/v10/domains.yaml
```

---

## 12. CRITICAL IMPLEMENTATION RULES

1. **EVERY response/event MUST carry `(project, workspace)` fields** - Non-negotiable
2. **Use MessagePack for WS, JSON for HTTP** - Encoding consistency
3. **All reads via HTTP, all writes/streams via WS** - Transmission boundary
4. **State machines are Core authority** - Clients consume, never re-derive
5. **Version number semantics matter** - Coordinator state versioning for cache invalidation
6. **Multi-workspace isolation is security** - Same-named workspaces in different projects are completely independent
7. **Protocol consistency checks are gated** - All PRs must pass `./scripts/tidyflow check`

---

**Generated**: TidyFlow v1.46+ Protocol Documentation
**Protocol Version**: 10 (MessagePack v6 Envelope)
**Last Updated**: 2025-01-15
