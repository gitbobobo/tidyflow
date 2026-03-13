import Foundation
import CoreFoundation
import SwiftUI

// MARK: - 会话级 Markdown 流式渲染协调器
//
// 替代每个 MarkdownTextView 各自持有独立 deferredRenderTask 的模式。
// 以 sessionId 为作用域，统一管理所有可见流式文本块的共享渲染节拍。
// MarkdownTextView 在流式期间向协调器注册，协调器统一 tick，
// 由 MarkdownTextView 在 onChange(of: coordinator.tickCount) 中自主决策是否渲染。
// 流式结束时协调器触发最终态提交并写入 MarkdownFinalStateCache。

// MARK: - AIChatStreamingRenderCoordinator

@MainActor
@Observable
final class AIChatStreamingRenderCoordinator {

    // MARK: - 共享渲染节拍

    /// 共享节拍计数器：每次 tick 递增。
    /// 注册中的 MarkdownTextView 在 onChange(of: coordinator.tickCount) 中自主决策渲染。
    private(set) var tickCount: Int = 0

    /// 已提交最终态的 partId → finalText 映射。
    /// MarkdownTextView 在 onChange 中检查并提交，完成后调用 consumeFinalized 清除。
    private(set) var finalizedParts: [String: String] = [:]

    // MARK: - 日志与诊断

    /// 当前活跃注册数，便于 perf fixture 观察
    private(set) var registeredCount: Int = 0
    /// 累计共享 tick 次数
    private(set) var totalTickCount: Int = 0

    // MARK: - 私有状态

    private var registeredPartIds: Set<String> = []
    // nonisolated(unsafe) 允许在 deinit（非 MainActor 上下文）中取消任务
    nonisolated(unsafe) private var tickTask: Task<Void, Never>?

    // MARK: - 注册 / 注销

    /// 注册一个正在流式输出的 part。
    func registerStreaming(partId: String) {
        guard !partId.isEmpty else { return }
        registeredPartIds.insert(partId)
        registeredCount = registeredPartIds.count
        ensureTickRunning()
    }

    /// 注销 part（流式结束或视图消失时调用）。
    func unregisterStreaming(partId: String) {
        guard !partId.isEmpty else { return }
        registeredPartIds.remove(partId)
        registeredCount = registeredPartIds.count
        if registeredPartIds.isEmpty {
            stopTick()
        }
    }

    // MARK: - 最终态提交

    /// 流式结束时，由 MarkdownTextView 调用，触发最终文本提交并广播。
    /// 协调器将 partId → finalText 写入 finalizedParts，触发观察者（MarkdownTextView）更新。
    func commitFinalText(partId: String, text: String) {
        guard !partId.isEmpty else { return }
        finalizedParts[partId] = text
        registeredPartIds.remove(partId)
        registeredCount = registeredPartIds.count
        if registeredPartIds.isEmpty {
            stopTick()
        }
    }

    /// MarkdownTextView 提交最终文本后调用，清除 finalizedParts 中的已消费条目。
    func consumeFinalized(partId: String) {
        finalizedParts.removeValue(forKey: partId)
    }

    // MARK: - 内部 tick 管理

    private func ensureTickRunning() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled else { break }
                self.totalTickCount += 1
                self.tickCount += 1
                TFLog.perf.debug(
                    "perf ai_markdown_coordinator tick=\(self.totalTickCount, privacy: .public) registered=\(self.registeredCount, privacy: .public)"
                )
            }
        }
    }

    private func stopTick() {
        tickTask?.cancel()
        tickTask = nil
    }

    deinit {
        tickTask?.cancel()
        tickTask = nil
    }
}
