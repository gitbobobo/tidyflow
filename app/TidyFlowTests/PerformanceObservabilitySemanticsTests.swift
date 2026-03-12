import XCTest
@testable import TidyFlow

/// 性能可观测共享模型语义测试（WI-006）
///
/// 覆盖：
/// - `LatencyMetricWindow` / `MemoryUsageSnapshot` / `CoreRuntimeMemorySnapshot` JSON 解码
/// - `ClientPerformanceReport` 解码与 `client_instance_id` 字段映射
/// - `WorkspacePerformanceSnapshot` 解码与 `project`/`workspace` 隔离键
/// - `PerformanceObservabilitySnapshot` 完整结构解码
/// - 多实例 `client_instance_id` 隔离（不同 ID 不互相覆盖）
/// - 关键路径延迟字段名 snake_case ↔ Swift camelCase 映射正确
final class PerformanceObservabilitySemanticsTests: XCTestCase {

    // MARK: - LatencyMetricWindow

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

    func testLatencyMetricWindow_empty_hasZeroValues() {
        let w = LatencyMetricWindow.empty
        XCTAssertEqual(w.lastMs, 0)
        XCTAssertEqual(w.p95Ms, 0)
        XCTAssertEqual(w.sampleCount, 0)
        XCTAssertEqual(w.windowSize, 128)
    }

    func testLatencyMetricWindow_equatable() {
        let w1 = LatencyMetricWindow(lastMs: 10, avgMs: 10, p95Ms: 10, maxMs: 10, sampleCount: 1, windowSize: 128)
        let w2 = LatencyMetricWindow(lastMs: 10, avgMs: 10, p95Ms: 10, maxMs: 10, sampleCount: 1, windowSize: 128)
        let w3 = LatencyMetricWindow(lastMs: 99, avgMs: 10, p95Ms: 10, maxMs: 99, sampleCount: 1, windowSize: 128)
        XCTAssertEqual(w1, w2)
        XCTAssertNotEqual(w1, w3)
    }

    // MARK: - MemoryUsageSnapshot

    func testMemoryUsageSnapshot_decodesAllFields() throws {
        let json = """
        {
            "current_bytes": 104857600,
            "peak_bytes": 209715200,
            "delta_from_baseline_bytes": -1024,
            "virtual_bytes": 524288000,
            "sample_count": 5
        }
        """.utf8Data
        let snap = try JSONDecoder().decode(MemoryUsageSnapshot.self, from: json)
        XCTAssertEqual(snap.currentBytes, 104_857_600)
        XCTAssertEqual(snap.peakBytes, 209_715_200)
        XCTAssertEqual(snap.deltaFromBaselineBytes, -1024)
        XCTAssertEqual(snap.virtualBytes, 524_288_000)
        XCTAssertEqual(snap.sampleCount, 5)
    }

    func testMemoryUsageSnapshot_optional_virtual_bytes_absent() throws {
        let json = """
        {
            "current_bytes": 10,
            "peak_bytes": 20,
            "delta_from_baseline_bytes": 0,
            "sample_count": 1
        }
        """.utf8Data
        let snap = try JSONDecoder().decode(MemoryUsageSnapshot.self, from: json)
        XCTAssertNil(snap.virtualBytes, "virtual_bytes 可选字段缺失时应为 nil")
    }

    // MARK: - CoreRuntimeMemorySnapshot

    func testCoreRuntimeMemorySnapshot_decodesAllFields() throws {
        let json = """
        {
            "resident_bytes": 100000000,
            "virtual_bytes": 200000000,
            "phys_footprint_bytes": 150000000,
            "sample_time_ms": 1710000000000
        }
        """.utf8Data
        let snap = try JSONDecoder().decode(CoreRuntimeMemorySnapshot.self, from: json)
        XCTAssertEqual(snap.residentBytes, 100_000_000)
        XCTAssertEqual(snap.virtualBytes, 200_000_000)
        XCTAssertEqual(snap.physFootprintBytes, 150_000_000)
        XCTAssertEqual(snap.sampleTimeMs, 1_710_000_000_000)
    }

    // MARK: - ClientPerformanceReport

    func testClientPerformanceReport_decodesClientInstanceId() throws {
        let json = makeClientReportJSON(clientInstanceId: "inst-abc-123", platform: "macos",
                                       project: "proj_x", workspace: "ws_default")
        let report = try JSONDecoder().decode(ClientPerformanceReport.self, from: json)
        XCTAssertEqual(report.clientInstanceId, "inst-abc-123")
        XCTAssertEqual(report.platform, "macos")
        XCTAssertEqual(report.project, "proj_x")
        XCTAssertEqual(report.workspace, "ws_default")
    }

    func testClientPerformanceReport_decodesKeyPathLatencyFields() throws {
        let json = makeClientReportJSON(
            clientInstanceId: "inst-001",
            platform: "ios",
            project: "p",
            workspace: "w",
            workspaceSwitchP95: 350,
            fileTreeRequestP95: 120,
            aiSessionListP95: 80,
            messageFlushP95: 45
        )
        let report = try JSONDecoder().decode(ClientPerformanceReport.self, from: json)
        XCTAssertEqual(report.workspaceSwitch.p95Ms, 350, "workspace_switch.p95_ms 映射")
        XCTAssertEqual(report.fileTreeRequest.p95Ms, 120, "file_tree_request.p95_ms 映射")
        XCTAssertEqual(report.aiSessionListRequest.p95Ms, 80, "ai_session_list_request.p95_ms 映射")
        XCTAssertEqual(report.aiMessageTailFlush.p95Ms, 45, "ai_message_tail_flush.p95_ms 映射")
    }

    // MARK: - client_instance_id 隔离

    func testClientInstanceId_isolation_multiple_reports_no_cross_contamination() throws {
        let json1 = makeClientReportJSON(clientInstanceId: "inst-A", platform: "macos",
                                        project: "proj_a", workspace: "ws1",
                                        workspaceSwitchP95: 1000)
        let json2 = makeClientReportJSON(clientInstanceId: "inst-B", platform: "ios",
                                        project: "proj_a", workspace: "ws1",
                                        workspaceSwitchP95: 20)
        let r1 = try JSONDecoder().decode(ClientPerformanceReport.self, from: json1)
        let r2 = try JSONDecoder().decode(ClientPerformanceReport.self, from: json2)

        XCTAssertEqual(r1.clientInstanceId, "inst-A")
        XCTAssertEqual(r2.clientInstanceId, "inst-B")
        XCTAssertEqual(r1.workspaceSwitch.p95Ms, 1000, "inst-A 的延迟不应被 inst-B 覆盖")
        XCTAssertEqual(r2.workspaceSwitch.p95Ms, 20, "inst-B 的延迟不应被 inst-A 覆盖")
        XCTAssertNotEqual(r1.platform, r2.platform, "不同实例 platform 字段应独立")
    }

    func testClientInstanceId_emptyString_decodes_without_crash() throws {
        let json = makeClientReportJSON(clientInstanceId: "", platform: "macos",
                                       project: "p", workspace: "w")
        let report = try JSONDecoder().decode(ClientPerformanceReport.self, from: json)
        XCTAssertEqual(report.clientInstanceId, "")
    }

    // MARK: - WorkspacePerformanceSnapshot

    func testWorkspacePerformanceSnapshot_decodesProjectAndWorkspace() throws {
        let json = makeWorkspaceSnapshotJSON(project: "proj_multi", workspace: "branch_a",
                                             fileIndexP95: 75)
        let snap = try JSONDecoder().decode(WorkspacePerformanceSnapshot.self, from: json)
        XCTAssertEqual(snap.project, "proj_multi")
        XCTAssertEqual(snap.workspace, "branch_a")
        XCTAssertEqual(snap.workspaceFileIndexRefresh.p95Ms, 75)
    }

    func testWorkspacePerformanceSnapshot_id_is_project_slash_workspace() throws {
        let json = makeWorkspaceSnapshotJSON(project: "proj_a", workspace: "ws1", fileIndexP95: 0)
        let snap = try JSONDecoder().decode(WorkspacePerformanceSnapshot.self, from: json)
        XCTAssertEqual(snap.id, "proj_a/ws1", "Identifiable.id 应为 project/workspace")
    }

    func testWorkspacePerformanceSnapshot_isolation_same_workspace_different_projects() throws {
        let jsonA = makeWorkspaceSnapshotJSON(project: "proj_a", workspace: "default",
                                              fileIndexP95: 3000)
        let jsonB = makeWorkspaceSnapshotJSON(project: "proj_b", workspace: "default",
                                              fileIndexP95: 10)
        let snapA = try JSONDecoder().decode(WorkspacePerformanceSnapshot.self, from: jsonA)
        let snapB = try JSONDecoder().decode(WorkspacePerformanceSnapshot.self, from: jsonB)
        XCTAssertEqual(snapA.project, "proj_a")
        XCTAssertEqual(snapB.project, "proj_b")
        XCTAssertEqual(snapA.workspaceFileIndexRefresh.p95Ms, 3000)
        XCTAssertEqual(snapB.workspaceFileIndexRefresh.p95Ms, 10)
        XCTAssertNotEqual(snapA.id, snapB.id, "不同 project 下的同名工作区 ID 应不同")
    }

    // MARK: - PerformanceObservabilitySnapshot

    func testPerformanceObservabilitySnapshot_empty_decodesWithoutCrash() throws {
        let json = """
        {
            "core_memory": {
                "resident_bytes": 0,
                "virtual_bytes": 0,
                "phys_footprint_bytes": 0,
                "sample_time_ms": 0
            },
            "ws_pipeline_latency": {
                "last_ms": 0, "avg_ms": 0, "p95_ms": 0,
                "max_ms": 0, "sample_count": 0, "window_size": 128
            },
            "snapshot_at": 0
        }
        """.utf8Data
        let obs = try JSONDecoder().decode(PerformanceObservabilitySnapshot.self, from: json)
        XCTAssertTrue(obs.workspaceMetrics.isEmpty, "缺失 workspace_metrics 时应为空数组")
        XCTAssertTrue(obs.clientMetrics.isEmpty, "缺失 client_metrics 时应为空数组")
        XCTAssertTrue(obs.diagnoses.isEmpty, "缺失 diagnoses 时应为空数组")
    }

    func testPerformanceObservabilitySnapshot_full_decodesAllSections() throws {
        let json = """
        {
            "core_memory": {
                "resident_bytes": 100000000,
                "virtual_bytes": 200000000,
                "phys_footprint_bytes": 150000000,
                "sample_time_ms": 1000
            },
            "ws_pipeline_latency": {
                "last_ms": 12, "avg_ms": 10, "p95_ms": 20,
                "max_ms": 30, "sample_count": 5, "window_size": 128
            },
            "workspace_metrics": [
                {
                    "project": "proj_a", "workspace": "ws1",
                    "system_snapshot_build": {"last_ms":1,"avg_ms":1,"p95_ms":1,"max_ms":1,"sample_count":1,"window_size":128},
                    "workspace_file_index_refresh": {"last_ms":50,"avg_ms":48,"p95_ms":80,"max_ms":100,"sample_count":10,"window_size":128},
                    "workspace_git_status_refresh": {"last_ms":5,"avg_ms":5,"p95_ms":8,"max_ms":10,"sample_count":3,"window_size":128},
                    "evolution_snapshot_read": {"last_ms":2,"avg_ms":2,"p95_ms":3,"max_ms":4,"sample_count":2,"window_size":128},
                    "snapshot_at": 1710000000000
                }
            ],
            "client_metrics": [
                {
                    "client_instance_id": "inst-xyz",
                    "platform": "macos",
                    "project": "proj_a",
                    "workspace": "ws1",
                    "memory": {"current_bytes":52428800,"peak_bytes":62914560,"delta_from_baseline_bytes":0,"sample_count":3},
                    "workspace_switch": {"last_ms":200,"avg_ms":180,"p95_ms":250,"max_ms":300,"sample_count":5,"window_size":128},
                    "file_tree_request": {"last_ms":40,"avg_ms":35,"p95_ms":60,"max_ms":80,"sample_count":8,"window_size":128},
                    "file_tree_expand": {"last_ms":10,"avg_ms":9,"p95_ms":15,"max_ms":20,"sample_count":4,"window_size":128},
                    "ai_session_list_request": {"last_ms":80,"avg_ms":75,"p95_ms":100,"max_ms":120,"sample_count":6,"window_size":128},
                    "ai_message_tail_flush": {"last_ms":30,"avg_ms":28,"p95_ms":45,"max_ms":60,"sample_count":7,"window_size":128},
                    "evidence_page_append": {"last_ms":15,"avg_ms":12,"p95_ms":25,"max_ms":30,"sample_count":5,"window_size":128},
                    "reported_at": 1710000001000
                }
            ],
            "diagnoses": [],
            "snapshot_at": 1710000001000
        }
        """.utf8Data
        let obs = try JSONDecoder().decode(PerformanceObservabilitySnapshot.self, from: json)
        XCTAssertEqual(obs.coreMemory.physFootprintBytes, 150_000_000)
        XCTAssertEqual(obs.wsPipelineLatency.p95Ms, 20)
        XCTAssertEqual(obs.workspaceMetrics.count, 1)
        XCTAssertEqual(obs.workspaceMetrics[0].project, "proj_a")
        XCTAssertEqual(obs.workspaceMetrics[0].workspaceFileIndexRefresh.p95Ms, 80)
        XCTAssertEqual(obs.clientMetrics.count, 1)
        XCTAssertEqual(obs.clientMetrics[0].clientInstanceId, "inst-xyz")
        XCTAssertEqual(obs.clientMetrics[0].workspaceSwitch.p95Ms, 250)
        XCTAssertEqual(obs.clientMetrics[0].fileTreeRequest.p95Ms, 60)
        XCTAssertEqual(obs.clientMetrics[0].memory.currentBytes, 52_428_800)
        XCTAssertTrue(obs.diagnoses.isEmpty)
    }

    func testPerformanceObservabilitySnapshot_equatable_empty_equals_staticEmpty() {
        let decoded = PerformanceObservabilitySnapshot.empty
        let manual = PerformanceObservabilitySnapshot(
            coreMemory: .empty,
            wsPipelineLatency: .empty,
            workspaceMetrics: [],
            clientMetrics: [],
            diagnoses: [],
            snapshotAt: 0
        )
        XCTAssertEqual(decoded, manual)
    }

    // MARK: - 关键路径字段映射完整性

    func testClientPerformanceReport_allKeyPathFields_mapToSwiftCamelCase() throws {
        // 验证 snake_case JSON 键映射为 Swift camelCase 属性
        let json = makeClientReportJSON(
            clientInstanceId: "inst-map-test",
            platform: "ios",
            project: "p",
            workspace: "w",
            workspaceSwitchP95: 100,
            fileTreeRequestP95: 200,
            fileTreeExpandP95: 300,
            aiSessionListP95: 400,
            messageFlushP95: 500,
            evidencePageAppendP95: 600
        )
        let r = try JSONDecoder().decode(ClientPerformanceReport.self, from: json)
        XCTAssertEqual(r.workspaceSwitch.p95Ms, 100, "workspace_switch → workspaceSwitch")
        XCTAssertEqual(r.fileTreeRequest.p95Ms, 200, "file_tree_request → fileTreeRequest")
        XCTAssertEqual(r.fileTreeExpand.p95Ms, 300, "file_tree_expand → fileTreeExpand")
        XCTAssertEqual(r.aiSessionListRequest.p95Ms, 400, "ai_session_list_request → aiSessionListRequest")
        XCTAssertEqual(r.aiMessageTailFlush.p95Ms, 500, "ai_message_tail_flush → aiMessageTailFlush")
        XCTAssertEqual(r.evidencePageAppend.p95Ms, 600, "evidence_page_append → evidencePageAppend")
    }

    // MARK: - 私有辅助方法

    private func makeClientReportJSON(
        clientInstanceId: String,
        platform: String,
        project: String,
        workspace: String,
        workspaceSwitchP95: UInt64 = 0,
        fileTreeRequestP95: UInt64 = 0,
        fileTreeExpandP95: UInt64 = 0,
        aiSessionListP95: UInt64 = 0,
        messageFlushP95: UInt64 = 0,
        evidencePageAppendP95: UInt64 = 0
    ) -> Data {
        let latency = { (p95: UInt64) -> String in
            """
            {"last_ms":\(p95),"avg_ms":\(p95),"p95_ms":\(p95),"max_ms":\(p95),"sample_count":1,"window_size":128}
            """
        }
        let str = """
        {
            "client_instance_id": "\(clientInstanceId)",
            "platform": "\(platform)",
            "project": "\(project)",
            "workspace": "\(workspace)",
            "memory": {"current_bytes":0,"peak_bytes":0,"delta_from_baseline_bytes":0,"sample_count":0},
            "workspace_switch": \(latency(workspaceSwitchP95)),
            "file_tree_request": \(latency(fileTreeRequestP95)),
            "file_tree_expand": \(latency(fileTreeExpandP95)),
            "ai_session_list_request": \(latency(aiSessionListP95)),
            "ai_message_tail_flush": \(latency(messageFlushP95)),
            "evidence_page_append": \(latency(evidencePageAppendP95)),
            "reported_at": 0
        }
        """
        return str.utf8Data
    }

    private func makeWorkspaceSnapshotJSON(
        project: String,
        workspace: String,
        fileIndexP95: UInt64
    ) -> Data {
        let latency = { (p95: UInt64) -> String in
            """
            {"last_ms":\(p95),"avg_ms":\(p95),"p95_ms":\(p95),"max_ms":\(p95),"sample_count":1,"window_size":128}
            """
        }
        let str = """
        {
            "project": "\(project)",
            "workspace": "\(workspace)",
            "system_snapshot_build": \(latency(0)),
            "workspace_file_index_refresh": \(latency(fileIndexP95)),
            "workspace_git_status_refresh": \(latency(0)),
            "evolution_snapshot_read": \(latency(0)),
            "snapshot_at": 0
        }
        """
        return str.utf8Data
    }
}

// MARK: - 私有扩展

private extension String {
    var utf8Data: Data { Data(utf8) }
}
