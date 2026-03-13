import XCTest
@testable import TidyFlow

/// 验证 AppState.normalizedEvolutionProfiles 的归一化逻辑：
/// - legacy "implement" 阶段正确分裂为 implement_general / implement_visual
/// - 显式配置优先于 legacy 映射（不被 "implement" 覆盖）
final class EvolutionAgentProfileNormalizationTests: XCTestCase {

    // MARK: - Legacy "implement" 分裂映射

    func testLegacyImplementSplitsIntoGeneralAndVisual() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)

        let general = normalized.first { $0.stage == "implement_general" }
        let visual = normalized.first { $0.stage == "implement_visual" }
        XCTAssertEqual(general?.aiTool, .copilot, "implement_general 应继承 legacy implement 的 aiTool")
        XCTAssertEqual(visual?.aiTool, .copilot, "implement_visual 应继承 legacy implement 的 aiTool")
    }

    // MARK: - 显式配置优先于 legacy 映射

    func testExplicitImplementGeneralWinsOverLegacyImplement() {
        // 服务端先返回 legacy implement(opencode)，再返回 implement_general(copilot)
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement", aiTool: .opencode, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "implement_general", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)

        let general = normalized.first { $0.stage == "implement_general" }
        XCTAssertEqual(general?.aiTool, .copilot, "显式 implement_general(copilot) 应优先于 legacy implement(opencode)")
    }

    func testExplicitImplementVisualWinsOverLegacyImplement() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement", aiTool: .opencode, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "implement_visual", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)

        let visual = normalized.first { $0.stage == "implement_visual" }
        XCTAssertEqual(visual?.aiTool, .copilot, "显式 implement_visual(copilot) 应优先于 legacy implement(opencode)")
    }

    // MARK: - 全显式配置（无 legacy）正确保留

    func testAllExplicitProfilesPreserved() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "direction", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "plan", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "implement_general", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "implement_visual", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "implement_advanced", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "verify", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "auto_commit", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "sync", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "integration", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)

        XCTAssertEqual(normalized.count, 9)
        XCTAssertTrue(normalized.allSatisfy { $0.aiTool == .copilot }, "所有阶段均应使用配置的 copilot")
    }

    // MARK: - 空输入返回默认配置

    func testEmptyInputReturnsDefaults() {
        let normalized = AppState.normalizedEvolutionProfiles([])
        let defaults = AppState.defaultEvolutionProfiles()
        XCTAssertEqual(normalized.count, defaults.count)
        XCTAssertTrue(normalized.allSatisfy { $0.aiTool == .codex }, "空输入应回退为默认 codex 配置")
    }

    // MARK: - 无效阶段名不进入结果

    func testInvalidStageNamesAreIgnored() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "nonexistent_stage", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let hasInvalid = normalized.contains { $0.stage == "nonexistent_stage" }
        XCTAssertFalse(hasInvalid, "无效阶段名不应出现在归一化结果中")
    }

    // MARK: - 各阶段 AI 工具图标来源映射

    func testImplementGeneralCopilotIconAsset() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement_general", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let stage = normalized.first { $0.stage == "implement_general" }
        XCTAssertEqual(stage?.aiTool, .copilot)
        XCTAssertEqual(stage?.aiTool.iconAssetName, "copilot-icon", "implement_general 配置 copilot 应使用 copilot-icon 资源")
    }

    func testImplementGeneralOpencodeIconAsset() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement_general", aiTool: .opencode, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let stage = normalized.first { $0.stage == "implement_general" }
        XCTAssertEqual(stage?.aiTool, .opencode)
        XCTAssertEqual(stage?.aiTool.iconAssetName, "opencode-icon", "implement_general 配置 opencode 应使用 opencode-icon 资源")
    }

    func testImplementVisualCopilotIconAsset() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement_visual", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let stage = normalized.first { $0.stage == "implement_visual" }
        XCTAssertEqual(stage?.aiTool, .copilot)
        XCTAssertEqual(stage?.aiTool.iconAssetName, "copilot-icon", "implement_visual 配置 copilot 应使用 copilot-icon 资源")
    }

    func testAutoCommitCopilotIconAsset() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "auto_commit", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let stage = normalized.first { $0.stage == "auto_commit" }
        XCTAssertEqual(stage?.aiTool, .copilot)
        XCTAssertEqual(stage?.aiTool.iconAssetName, "copilot-icon", "auto_commit 配置 copilot 应使用 copilot-icon 资源")
    }

    func testAutoCommitOpencodeIconAsset() {
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "auto_commit", aiTool: .opencode, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let stage = normalized.first { $0.stage == "auto_commit" }
        XCTAssertEqual(stage?.aiTool, .opencode)
        XCTAssertEqual(stage?.aiTool.iconAssetName, "opencode-icon", "auto_commit 配置 opencode 应使用 opencode-icon 资源")
    }

    // MARK: - AI 工具图标资源名称固定契约

    func testAIToolIconAssetNames() {
        XCTAssertEqual(AIChatTool.copilot.iconAssetName, "copilot-icon")
        XCTAssertEqual(AIChatTool.opencode.iconAssetName, "opencode-icon")
        XCTAssertEqual(AIChatTool.codex.iconAssetName, "codex-icon")
    }

    // MARK: - 显式配置与 legacy 混合时各关键阶段图标来源正确

    func testExplicitCopilotOverridesLegacyOpencodeForImplementGeneral() {
        // 服务端返回 legacy implement(opencode)，客户端覆写 implement_general(copilot)
        let profiles: [EvolutionStageProfileInfoV2] = [
            EvolutionStageProfileInfoV2(stage: "implement", aiTool: .opencode, mode: nil, model: nil, configOptions: [:]),
            EvolutionStageProfileInfoV2(stage: "implement_general", aiTool: .copilot, mode: nil, model: nil, configOptions: [:]),
        ]
        let normalized = AppState.normalizedEvolutionProfiles(profiles)
        let general = normalized.first { $0.stage == "implement_general" }
        XCTAssertEqual(general?.aiTool, .copilot, "显式 implement_general(copilot) 图标来源应为 copilot-icon，不受 legacy opencode 影响")
        XCTAssertEqual(general?.aiTool.iconAssetName, "copilot-icon")
    }
}
