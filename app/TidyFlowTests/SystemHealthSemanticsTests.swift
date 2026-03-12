import XCTest
@testable import TidyFlow

/// 系统健康与性能诊断共享语义测试（WI-006）
///
/// 覆盖：
/// - `PerformanceDiagnosis` 完整字段解码
/// - `PerformanceDiagnosisReason` 枚举原始值与 snake_case 映射
/// - `PerformanceDiagnosisSeverity` 严重度排序（info < warning < critical）
/// - `PerformanceDiagnosisScope` 枚举 raw value（含 client_instance）
/// - `HealthContext` 在诊断中的字段语义
/// - `client_instance_id` 可选字段：system/workspace scope 时为 nil，
///   client_instance scope 时必须存在
final class SystemHealthSemanticsTests: XCTestCase {

    // MARK: - PerformanceDiagnosisReason 枚举值映射

    func testPerformanceDiagnosisReason_rawValues_matchProtocol() {
        let cases: [(PerformanceDiagnosisReason, String)] = [
            (.wsPipelineLatencyHigh, "ws_pipeline_latency_high"),
            (.workspaceSwitchLatencyHigh, "workspace_switch_latency_high"),
            (.fileTreeLatencyHigh, "file_tree_latency_high"),
            (.aiSessionListLatencyHigh, "ai_session_list_latency_high"),
            (.messageFlushLatencyHigh, "message_flush_latency_high"),
            (.coreMemoryPressure, "core_memory_pressure"),
            (.clientMemoryPressure, "client_memory_pressure"),
            (.memoryGrowthUnbounded, "memory_growth_unbounded"),
            (.queueBackpressureHigh, "queue_backpressure_high"),
            (.crossLayerLatencyMismatch, "cross_layer_latency_mismatch"),
        ]
        for (reason, raw) in cases {
            XCTAssertEqual(reason.rawValue, raw, "\(reason) 的 rawValue 应为 \(raw)")
        }
    }

    func testPerformanceDiagnosisReason_allCases_count() {
        // 协议定义了 10 个原因码，枚举应完整
        XCTAssertEqual(PerformanceDiagnosisReason.allCases.count, 10,
                       "PerformanceDiagnosisReason 应包含 10 个 case")
    }

    func testPerformanceDiagnosisReason_decodesFromSnakeCaseJSON() throws {
        let json = "\"core_memory_pressure\"".utf8Data
        let reason = try JSONDecoder().decode(PerformanceDiagnosisReason.self, from: json)
        XCTAssertEqual(reason, .coreMemoryPressure)
    }

    func testPerformanceDiagnosisReason_crossLayerLatencyMismatch_decodes() throws {
        let json = "\"cross_layer_latency_mismatch\"".utf8Data
        let reason = try JSONDecoder().decode(PerformanceDiagnosisReason.self, from: json)
        XCTAssertEqual(reason, .crossLayerLatencyMismatch)
    }

    // MARK: - PerformanceDiagnosisSeverity 严重度排序

    func testPerformanceDiagnosisSeverity_ordering_info_less_than_warning() {
        XCTAssertLessThan(PerformanceDiagnosisSeverity.info, .warning)
    }

    func testPerformanceDiagnosisSeverity_ordering_warning_less_than_critical() {
        XCTAssertLessThan(PerformanceDiagnosisSeverity.warning, .critical)
    }

    func testPerformanceDiagnosisSeverity_ordering_info_less_than_critical() {
        XCTAssertLessThan(PerformanceDiagnosisSeverity.info, .critical)
    }

    func testPerformanceDiagnosisSeverity_comparable_symmetry() {
        XCTAssertFalse(PerformanceDiagnosisSeverity.critical < .warning)
        XCTAssertFalse(PerformanceDiagnosisSeverity.warning < .info)
    }

    func testPerformanceDiagnosisSeverity_rawValues_matchProtocol() {
        XCTAssertEqual(PerformanceDiagnosisSeverity.info.rawValue, "info")
        XCTAssertEqual(PerformanceDiagnosisSeverity.warning.rawValue, "warning")
        XCTAssertEqual(PerformanceDiagnosisSeverity.critical.rawValue, "critical")
    }

    func testPerformanceDiagnosisSeverity_decodesFromJSON() throws {
        let json = "\"critical\"".utf8Data
        let sev = try JSONDecoder().decode(PerformanceDiagnosisSeverity.self, from: json)
        XCTAssertEqual(sev, .critical)
    }

    // MARK: - PerformanceDiagnosisScope

    func testPerformanceDiagnosisScope_rawValues_matchProtocol() {
        XCTAssertEqual(PerformanceDiagnosisScope.system.rawValue, "system")
        XCTAssertEqual(PerformanceDiagnosisScope.workspace.rawValue, "workspace")
        XCTAssertEqual(PerformanceDiagnosisScope.clientInstance.rawValue, "client_instance")
    }

    func testPerformanceDiagnosisScope_clientInstance_rawValue_uses_underscore() throws {
        // 特别验证 client_instance（含下划线）的 snake_case 映射
        let json = "\"client_instance\"".utf8Data
        let scope = try JSONDecoder().decode(PerformanceDiagnosisScope.self, from: json)
        XCTAssertEqual(scope, .clientInstance)
    }

    func testPerformanceDiagnosisScope_allCases_count() {
        XCTAssertEqual(PerformanceDiagnosisScope.allCases.count, 3,
                       "PerformanceDiagnosisScope 应有 3 个 case")
    }

    // MARK: - PerformanceDiagnosis 完整解码

    func testPerformanceDiagnosis_system_scope_decodes_all_fields() throws {
        let json = makePerformanceDiagnosisJSON(
            diagnosisId: "perf:core_memory_pressure:system:1710000000000",
            scope: "system",
            severity: "critical",
            reason: "core_memory_pressure",
            summary: "Core 内存占用 800MB，超过临界阈值 768MB",
            evidence: ["core.phys_footprint_bytes=838860800"],
            recommendedAction: "检查缓存淘汰策略",
            clientInstanceId: nil
        )
        let d = try JSONDecoder().decode(PerformanceDiagnosis.self, from: json)
        XCTAssertEqual(d.diagnosisId, "perf:core_memory_pressure:system:1710000000000")
        XCTAssertEqual(d.scope, .system)
        XCTAssertEqual(d.severity, .critical)
        XCTAssertEqual(d.reason, .coreMemoryPressure)
        XCTAssertFalse(d.summary.isEmpty)
        XCTAssertEqual(d.evidence.count, 1)
        XCTAssertFalse(d.recommendedAction.isEmpty)
        XCTAssertNil(d.clientInstanceId, "system scope 的 clientInstanceId 应为 nil")
    }

    func testPerformanceDiagnosis_clientInstance_scope_requires_clientInstanceId() throws {
        let json = makePerformanceDiagnosisJSON(
            diagnosisId: "perf:client_memory_pressure:inst-abc:1710000000000",
            scope: "client_instance",
            severity: "warning",
            reason: "client_memory_pressure",
            summary: "客户端内存 450MB，超过 iOS 警告阈值",
            evidence: ["client.memory.current_bytes=471859200"],
            recommendedAction: "监控内存增长趋势",
            clientInstanceId: "inst-abc"
        )
        let d = try JSONDecoder().decode(PerformanceDiagnosis.self, from: json)
        XCTAssertEqual(d.scope, .clientInstance)
        XCTAssertEqual(d.clientInstanceId, "inst-abc",
                       "client_instance scope 的 clientInstanceId 应被解码")
        XCTAssertEqual(d.severity, .warning)
    }

    func testPerformanceDiagnosis_workspace_scope_decodes_context() throws {
        let json = makePerformanceDiagnosisJSON(
            diagnosisId: "perf:file_tree_latency_high:proj_a:ws1:1710000000000",
            scope: "workspace",
            severity: "warning",
            reason: "file_tree_latency_high",
            summary: "[proj_a/ws1] 文件索引刷新 p95=800ms",
            evidence: ["workspace_file_index_refresh.p95_ms=800"],
            recommendedAction: "检查工作区文件数量",
            clientInstanceId: nil,
            contextProject: "proj_a",
            contextWorkspace: "ws1"
        )
        let d = try JSONDecoder().decode(PerformanceDiagnosis.self, from: json)
        XCTAssertEqual(d.scope, .workspace)
        XCTAssertEqual(d.reason, .fileTreeLatencyHigh)
        XCTAssertNil(d.clientInstanceId, "workspace scope 的 clientInstanceId 应为 nil")
    }

    func testPerformanceDiagnosis_identifiable_id_is_diagnosisId() throws {
        let json = makePerformanceDiagnosisJSON(
            diagnosisId: "perf:queue_backpressure_high:system:9999",
            scope: "system",
            severity: "info",
            reason: "queue_backpressure_high",
            summary: "队列略有积压",
            evidence: [],
            recommendedAction: "监控趋势",
            clientInstanceId: nil
        )
        let d = try JSONDecoder().decode(PerformanceDiagnosis.self, from: json)
        XCTAssertEqual(d.id, d.diagnosisId, "Identifiable.id 应等于 diagnosisId")
    }

    func testPerformanceDiagnosis_equatable_two_identical_instances() throws {
        let json = makePerformanceDiagnosisJSON(
            diagnosisId: "perf:ws_pipeline_latency_high:system:1",
            scope: "system",
            severity: "warning",
            reason: "ws_pipeline_latency_high",
            summary: "WS 管线 120ms",
            evidence: ["ws_dispatch.last_ms=120"],
            recommendedAction: "监控",
            clientInstanceId: nil
        )
        let d1 = try JSONDecoder().decode(PerformanceDiagnosis.self, from: json)
        let d2 = try JSONDecoder().decode(PerformanceDiagnosis.self, from: json)
        XCTAssertEqual(d1, d2)
    }

    // MARK: - 多诊断数组解码（PerformanceObservabilitySnapshot.diagnoses）

    func testMultipleDiagnoses_decode_preserves_all_entries() throws {
        let json = """
        [
            \(makeDiagnosisJSONString(id: "diag-1", reason: "core_memory_pressure", scope: "system", severity: "critical")),
            \(makeDiagnosisJSONString(id: "diag-2", reason: "file_tree_latency_high", scope: "workspace", severity: "warning")),
            \(makeDiagnosisJSONString(id: "diag-3", reason: "client_memory_pressure", scope: "client_instance", severity: "warning", clientInstanceId: "inst-xyz"))
        ]
        """.utf8Data
        let diagnoses = try JSONDecoder().decode([PerformanceDiagnosis].self, from: json)
        XCTAssertEqual(diagnoses.count, 3)
        XCTAssertEqual(diagnoses[0].diagnosisId, "diag-1")
        XCTAssertEqual(diagnoses[1].diagnosisId, "diag-2")
        XCTAssertEqual(diagnoses[2].diagnosisId, "diag-3")
        XCTAssertEqual(diagnoses[2].clientInstanceId, "inst-xyz")
        XCTAssertNil(diagnoses[0].clientInstanceId, "system scope 的 clientInstanceId 应为 nil")
    }

    func testMultipleDiagnoses_severity_comparison_works_for_sorting() throws {
        let json = """
        [
            \(makeDiagnosisJSONString(id: "d1", reason: "core_memory_pressure", scope: "system", severity: "info")),
            \(makeDiagnosisJSONString(id: "d2", reason: "core_memory_pressure", scope: "system", severity: "critical")),
            \(makeDiagnosisJSONString(id: "d3", reason: "core_memory_pressure", scope: "system", severity: "warning"))
        ]
        """.utf8Data
        let diagnoses = try JSONDecoder().decode([PerformanceDiagnosis].self, from: json)
        let sorted = diagnoses.sorted { $0.severity < $1.severity }
        XCTAssertEqual(sorted[0].severity, .info)
        XCTAssertEqual(sorted[1].severity, .warning)
        XCTAssertEqual(sorted[2].severity, .critical)
    }

    // MARK: - 私有辅助方法

    private func makePerformanceDiagnosisJSON(
        diagnosisId: String,
        scope: String,
        severity: String,
        reason: String,
        summary: String,
        evidence: [String],
        recommendedAction: String,
        clientInstanceId: String?,
        contextProject: String? = nil,
        contextWorkspace: String? = nil
    ) -> Data {
        let evidenceJSON = evidence.map { "\"\($0)\"" }.joined(separator: ",")
        let clientIdJSON: String
        if let cid = clientInstanceId {
            clientIdJSON = ", \"client_instance_id\": \"\(cid)\""
        } else {
            clientIdJSON = ""
        }
        let contextProject = contextProject.map { "\"project\": \"\($0)\"," } ?? ""
        let contextWorkspace = contextWorkspace.map { "\"workspace\": \"\($0)\"" } ?? "\"workspace\": null"
        let str = """
        {
            "diagnosis_id": "\(diagnosisId)",
            "scope": "\(scope)",
            "severity": "\(severity)",
            "reason": "\(reason)",
            "summary": "\(summary)",
            "evidence": [\(evidenceJSON)],
            "recommended_action": "\(recommendedAction)",
            "context": {\(contextProject) \(contextWorkspace)},
            "diagnosed_at": 1710000000000
            \(clientIdJSON)
        }
        """
        return str.utf8Data
    }

    private func makeDiagnosisJSONString(
        id: String,
        reason: String,
        scope: String,
        severity: String,
        clientInstanceId: String? = nil
    ) -> String {
        let clientIdPart: String
        if let cid = clientInstanceId {
            clientIdPart = ", \"client_instance_id\": \"\(cid)\""
        } else {
            clientIdPart = ""
        }
        return """
        {
            "diagnosis_id": "\(id)",
            "scope": "\(scope)",
            "severity": "\(severity)",
            "reason": "\(reason)",
            "summary": "test summary",
            "evidence": [],
            "recommended_action": "test action",
            "context": {},
            "diagnosed_at": 0
            \(clientIdPart)
        }
        """
    }
}

// MARK: - 私有扩展

private extension String {
    var utf8Data: Data { Data(utf8) }
}
