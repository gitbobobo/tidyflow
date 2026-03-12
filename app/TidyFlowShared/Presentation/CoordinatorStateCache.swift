import Foundation

// MARK: - 跨平台协调层状态映射
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// macOS 与 iOS 双端通过同一套映射规则消费 Core 协调层状态，
// 不在视图层重复推导治理语义。
//
// 设计约束：
// - 状态映射不持有任何平台类型
// - 多工作区通过 globalKey ("project:workspace") 隔离
// - Core 是状态权威源，客户端只做投影和缓存

/// 协调层状态缓存——跨平台共享的协调状态管理入口。
///
/// 双端通过此类维护工作区级协调状态缓存。
/// 所有状态变更通过 `apply(_:)` 方法驱动，不允许直接修改内部字段。
public final class CoordinatorStateCache: @unchecked Sendable {

    // MARK: - 内部存储

    /// 按 globalKey 缓存的工作区协调状态
    private var cache: [String: WorkspaceCoordinatorState] = [:]

    /// 最后一次全局状态版本（用于增量更新判断）
    private(set) var lastGlobalVersion: UInt64 = 0

    // MARK: - 初始化

    public init() {}

    // MARK: - 状态更新入口

    /// 应用输入事件并更新缓存
    @discardableResult
    public func apply(_ input: CoordinatorStateInput) -> CoordinatorStateChangeResult {
        switch input {
        case .updateWorkspace(let state):
            let key = state.id.globalKey
            let previous = cache[key]
            cache[key] = state
            if state.version > lastGlobalVersion {
                lastGlobalVersion = state.version
            }
            let changed = previous != state
            return CoordinatorStateChangeResult(
                key: key,
                changed: changed,
                previousHealth: previous?.health,
                currentHealth: state.health
            )

        case .removeWorkspace(let id):
            let key = id.globalKey
            let previous = cache.removeValue(forKey: key)
            return CoordinatorStateChangeResult(
                key: key,
                changed: previous != nil,
                previousHealth: previous?.health,
                currentHealth: nil
            )

        case .batchUpdate(let states):
            var anyChanged = false
            for state in states {
                let key = state.id.globalKey
                let previous = cache[key]
                cache[key] = state
                if state.version > lastGlobalVersion {
                    lastGlobalVersion = state.version
                }
                if previous != state { anyChanged = true }
            }
            return CoordinatorStateChangeResult(
                key: "_batch",
                changed: anyChanged,
                previousHealth: nil,
                currentHealth: nil
            )

        case .clear:
            let hadEntries = !cache.isEmpty
            cache.removeAll()
            lastGlobalVersion = 0
            return CoordinatorStateChangeResult(
                key: "_all",
                changed: hadEntries,
                previousHealth: nil,
                currentHealth: nil
            )
        }
    }

    // MARK: - 查询接口

    /// 获取指定工作区的协调状态
    public func state(for id: CoordinatorWorkspaceId) -> WorkspaceCoordinatorState? {
        cache[id.globalKey]
    }

    /// 通过 globalKey 获取协调状态
    public func state(forGlobalKey key: String) -> WorkspaceCoordinatorState? {
        cache[key]
    }

    /// 获取指定项目下所有工作区的协调状态
    public func states(forProject project: String) -> [WorkspaceCoordinatorState] {
        let prefix = "\(project):"
        return cache
            .filter { $0.key.hasPrefix(prefix) }
            .map { $0.value }
    }

    /// 获取所有缓存的协调状态
    public var allStates: [WorkspaceCoordinatorState] {
        Array(cache.values)
    }

    /// 缓存的工作区数量
    public var count: Int {
        cache.count
    }

    /// 缓存是否为空
    public var isEmpty: Bool {
        cache.isEmpty
    }

    // MARK: - 投影接口

    /// 获取整体系统健康度（所有工作区中最差的健康度）
    public var systemHealth: CoordinatorHealth {
        var worst: CoordinatorHealth = .healthy
        for state in cache.values {
            switch state.health {
            case .faulted:
                return .faulted
            case .degraded:
                worst = .degraded
            case .healthy:
                break
            }
        }
        return worst
    }

    /// 获取指定工作区是否需要关注（非 healthy）
    public func needsAttention(for id: CoordinatorWorkspaceId) -> Bool {
        guard let state = state(for: id) else { return false }
        return state.health != .healthy
    }

    /// 获取所有需要关注的工作区 ID
    public var workspacesNeedingAttention: [CoordinatorWorkspaceId] {
        cache.values
            .filter { $0.health != .healthy }
            .map { $0.id }
    }

    // MARK: - 项目级操作

    /// 移除整个项目下所有工作区的协调状态（项目删除时调用）。
    /// - Returns: 移除的工作区数量
    @discardableResult
    public func removeProject(_ project: String) -> Int {
        let prefix = "\(project):"
        let toRemove = cache.keys.filter { $0.hasPrefix(prefix) }
        toRemove.forEach { cache.removeValue(forKey: $0) }
        return toRemove.count
    }

    /// 获取指定项目下所有工作区的 ID 列表
    public func allWorkspaceIds(forProject project: String) -> [CoordinatorWorkspaceId] {
        states(forProject: project).map { $0.id }
    }

    // MARK: - 多域聚合投影

    /// 获取指定工作区的多域聚合摘要，供工作区概览视图消费。
    /// 双端通过此投影获取文件/终端/AI 三域状态，不在视图层重复推导。
    public func aggregatedSummary(for id: CoordinatorWorkspaceId) -> WorkspaceAggregatedSummary {
        guard let state = state(for: id) else {
            return WorkspaceAggregatedSummary(
                id: id,
                health: .healthy,
                hasActiveAISessions: false,
                hasActiveTerminals: false,
                fileIsReady: false,
                aiActiveSessionCount: 0,
                terminalAliveCount: 0
            )
        }
        return WorkspaceAggregatedSummary(
            id: id,
            health: state.health,
            hasActiveAISessions: state.ai.phase == .active,
            hasActiveTerminals: state.terminal.phase == .active,
            fileIsReady: state.file.phase == .ready,
            aiActiveSessionCount: state.ai.activeSessionCount,
            terminalAliveCount: state.terminal.aliveCount
        )
    }
}

// MARK: - 状态输入事件

/// 协调层状态缓存的输入事件
public enum CoordinatorStateInput: Equatable, Sendable {
    /// 更新单个工作区的协调状态
    case updateWorkspace(WorkspaceCoordinatorState)
    /// 移除工作区（工作区被删除时）
    case removeWorkspace(CoordinatorWorkspaceId)
    /// 批量更新多个工作区状态（快照恢复等场景）
    case batchUpdate([WorkspaceCoordinatorState])
    /// 清空所有缓存（断开连接时）
    case clear
}

// MARK: - 状态变更结果

/// 状态变更结果
public struct CoordinatorStateChangeResult: Equatable, Sendable {
    /// 变更的 globalKey 或 "_batch"/"_all"
    public let key: String
    /// 是否实际发生了变更
    public let changed: Bool
    /// 变更前的健康度
    public let previousHealth: CoordinatorHealth?
    /// 变更后的健康度
    public let currentHealth: CoordinatorHealth?

    /// 健康度是否发生了变化
    public var healthChanged: Bool {
        previousHealth != currentHealth
    }
}

// MARK: - 多域聚合摘要

/// 工作区多域聚合摘要——供工作区概览视图消费的共享投影类型。
/// macOS 与 iOS 双端通过同一结构体表达工作区的健康度与活跃资源概况，
/// 不在视图层对 AI/终端/文件三域状态各自重复推导。
public struct WorkspaceAggregatedSummary: Equatable, Sendable {
    /// 工作区身份
    public let id: CoordinatorWorkspaceId
    /// 三域综合健康度
    public let health: CoordinatorHealth
    /// 是否有活跃 AI 会话
    public let hasActiveAISessions: Bool
    /// 是否有活跃终端
    public let hasActiveTerminals: Bool
    /// 文件系统是否就绪（watching 相位）
    public let fileIsReady: Bool
    /// 活跃 AI 会话数量
    public let aiActiveSessionCount: Int
    /// 存活终端数量
    public let terminalAliveCount: Int

    /// 工作区是否有任何活跃资源
    public var hasActiveResources: Bool {
        hasActiveAISessions || hasActiveTerminals
    }

    /// 工作区是否需要关注（健康度非 healthy）
    public var needsAttention: Bool {
        health != .healthy
    }
}
