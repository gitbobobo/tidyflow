import XCTest
@testable import TidyFlow

/// 验证自主进化阶段聊天入口可用性相关的逻辑：
/// - auto_commit 阶段应与其他阶段一致地包含在归一化配置中
/// - 所有标准阶段均出现在默认配置里（聊天入口依赖阶段配置）
final class EvolutionStageChatAvailabilityTests: XCTestCase {

    // MARK: - auto_commit 包含在默认配置中

    func testAutoCommitStageIncludedInDefaultProfiles() {
        let defaults = AppState.defaultEvolutionProfiles()
        let stages = defaults.map { $0.stage }
        XCTAssertTrue(stages.contains("auto_commit"), "默认配置应包含 auto_commit 阶段")
    }

    // MARK: - auto_commit 包含在归一化配置中

    func testAutoCommitPreservedAfterNormalization() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "auto_commit", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let autoCommit = normalized.first { $0.stage == "auto_commit" }
        XCTAssertNotNil(autoCommit, "归一化后 auto_commit 阶段应存在")
        XCTAssertEqual(autoCommit?.aiTool, .copilot, "归一化后 auto_commit 的 aiTool 应与配置一致")
    }

    // MARK: - 全部标准阶段均出现在配置里（聊天入口覆盖）

    func testAllStandardStagesInDefaultProfiles() {
        let expected: Set<String> = [
            "direction", "plan",
            "implement_general", "implement_visual", "implement_advanced",
            "verify", "auto_commit",
            "sync", "integration",
        ]
        let defaults = AppState.defaultEvolutionProfiles()
        let actual = Set(defaults.map { $0.stage })
        XCTAssertEqual(actual, expected, "默认配置应包含全部 9 个标准阶段")
    }

    // MARK: - 显式全量配置归一化后 auto_commit 仍正确保留

    func testFullExplicitConfigPreservesAutoCommit() {
        let profiles: [EvolutionStageProfileInfoV2] = AppState.defaultEvolutionProfiles().map {
            EvolutionStageProfileInfoV2(stage: $0.stage, aiTool: .copilot, mode: nil, model: nil, configOptions: [:])
        }
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let autoCommit = normalized.first { $0.stage == "auto_commit" }
        XCTAssertEqual(autoCommit?.aiTool, .copilot, "全量显式配置归一化后 auto_commit 应保留 copilot")
    }

    // MARK: - legacy implement 展开时不影响 auto_commit

    func testLegacyImplementDoesNotAffectAutoCommit() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement", aiTool: .opencode, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "auto_commit", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let autoCommit = normalized.first { $0.stage == "auto_commit" }
        XCTAssertEqual(autoCommit?.aiTool, .copilot, "legacy implement 展开不应影响 auto_commit 的 aiTool")
    }
}
