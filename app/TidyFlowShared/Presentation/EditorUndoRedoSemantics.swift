import Foundation

// MARK: - 编辑器撤销/重做共享语义层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 定义跨 macOS/iOS 共享的编辑历史类型与纯逻辑 API。
//
// 设计约束：
// - 全部值类型，平台状态容器按 EditorDocumentKey 存储。
// - 选区使用 UTF-16 offset（与 NSTextView/UITextView 的 NSRange 一致），
//   避免桥接层再做二次决策。
// - 命令合并规则固定：连续输入或连续退格在 600ms 内按相邻区间合并。
// - 程序化回放（撤销/重做写回文本）不再次入栈。

// MARK: - 选区快照（兼容类型）

/// 单选区快照，保留为兼容桥接别名或主选区快照。
/// 新代码应优先使用 `EditorSelectionRegion` 和 `EditorSelectionSet`。
public struct EditorSelectionSnapshot: Equatable, Sendable {
    /// 选区起始位置（UTF-16 offset）
    public let location: Int
    /// 选区长度（UTF-16 offset）
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

// MARK: - 多选区值类型

/// 单个选区区域（UTF-16 offset），支持主选区标记。
public struct EditorSelectionRegion: Equatable, Sendable {
    /// 选区起始位置（UTF-16 offset）
    public let location: Int
    /// 选区长度（UTF-16 offset）
    public let length: Int
    /// 是否为主选区
    public let isPrimary: Bool

    public init(location: Int, length: Int, isPrimary: Bool = false) {
        self.location = location
        self.length = length
        self.isPrimary = isPrimary
    }

    /// 选区结束位置（UTF-16 offset）
    public var endLocation: Int { location + length }

    /// 转换为兼容的 `EditorSelectionSnapshot`
    public var snapshot: EditorSelectionSnapshot {
        EditorSelectionSnapshot(location: location, length: length)
    }
}

/// 文档当前全部选区的值类型集合。
///
/// 设计约束：
/// - 至少有一个主选区。
/// - 归一化后按 `location` 升序，重叠或相邻选区合并。
/// - 所有偏移使用 UTF-16。
public struct EditorSelectionSet: Equatable, Sendable {
    /// 所有选区区域
    public let regions: [EditorSelectionRegion]

    public init(regions: [EditorSelectionRegion]) {
        precondition(!regions.isEmpty, "EditorSelectionSet 至少需要一个选区")
        if regions.contains(where: { $0.isPrimary }) {
            self.regions = regions
        } else {
            var adjusted = regions
            adjusted[0] = EditorSelectionRegion(
                location: regions[0].location,
                length: regions[0].length,
                isPrimary: true
            )
            self.regions = adjusted
        }
    }

    /// 主选区
    public var primarySelection: EditorSelectionRegion {
        regions.first(where: { $0.isPrimary }) ?? regions[0]
    }

    /// 主选区的兼容快照
    public var primarySnapshot: EditorSelectionSnapshot {
        primarySelection.snapshot
    }

    /// 附加选区（非主选区）
    public var additionalSelections: [EditorSelectionRegion] {
        regions.filter { !$0.isPrimary }
    }

    /// 选区数量
    public var count: Int { regions.count }

    /// 是否为单选区
    public var isSingleSelection: Bool { regions.count == 1 }

    // MARK: - 工厂方法

    /// 从单个位置和长度构建仅含一个主选区的集合
    public static func single(location: Int, length: Int) -> EditorSelectionSet {
        EditorSelectionSet(regions: [
            EditorSelectionRegion(location: location, length: length, isPrimary: true)
        ])
    }

    /// 从兼容快照构建仅含一个主选区的集合
    public static func single(_ snapshot: EditorSelectionSnapshot) -> EditorSelectionSet {
        .single(location: snapshot.location, length: snapshot.length)
    }

    /// 零长度主选区（文档开头）
    public static let zero = EditorSelectionSet.single(location: 0, length: 0)

    // MARK: - 归一化

    /// 按 location 升序排序后合并重叠选区
    public func normalized() -> EditorSelectionSet {
        sortedByLocation().mergedOverlaps()
    }

    /// 按 location 升序排序
    public func sortedByLocation() -> EditorSelectionSet {
        let sorted = regions.sorted { $0.location < $1.location }
        return EditorSelectionSet(regions: sorted)
    }

    /// 合并重叠或相邻选区，保留主选区标记
    public func mergedOverlaps() -> EditorSelectionSet {
        guard regions.count > 1 else { return self }
        let sorted = regions.sorted { $0.location < $1.location }
        var merged: [EditorSelectionRegion] = [sorted[0]]

        for i in 1..<sorted.count {
            let current = sorted[i]
            let last = merged[merged.count - 1]

            if current.location <= last.endLocation {
                let newEnd = max(last.endLocation, current.endLocation)
                let isPrimary = last.isPrimary || current.isPrimary
                merged[merged.count - 1] = EditorSelectionRegion(
                    location: last.location,
                    length: newEnd - last.location,
                    isPrimary: isPrimary
                )
            } else {
                merged.append(current)
            }
        }

        return EditorSelectionSet(regions: merged)
    }

    /// 将所有选区钳制到有效 UTF-16 偏移范围
    public func clamped(toUTF16Length maxLength: Int) -> EditorSelectionSet {
        let clamped = regions.map { region -> EditorSelectionRegion in
            let loc = min(max(region.location, 0), maxLength)
            let endLoc = min(max(region.endLocation, 0), maxLength)
            return EditorSelectionRegion(
                location: loc,
                length: endLoc - loc,
                isPrimary: region.isPrimary
            )
        }
        return EditorSelectionSet(regions: clamped)
    }
}

// MARK: - 文本变更

/// 一次原子文本替换（插入/删除/替换统一为此模型）
public struct EditorTextMutation: Equatable, Sendable {
    /// 被替换区间的起始位置（UTF-16 offset）
    public let rangeLocation: Int
    /// 被替换区间的长度（UTF-16 offset）
    public let rangeLength: Int
    /// 替换文本
    public let replacementText: String

    public init(rangeLocation: Int, rangeLength: Int, replacementText: String) {
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
        self.replacementText = replacementText
    }
}

// MARK: - 编辑命令

/// 历史栈中记录的命令对象，支持单次命令包含多个原子 mutation（多光标编辑）。
///
/// `mutations` 按 `rangeLocation` 降序排列（逆序应用以避免偏移失效）。
/// `replacedTexts` 与 `mutations` 一一对应。
/// 一条多 mutation 命令在撤销/重做时视为一条历史记录。
public struct EditorEditCommand: Equatable, Sendable {
    /// 批量文本变更（按 location 降序排列，逆序应用以避免偏移失效）
    public let mutations: [EditorTextMutation]
    /// 变更前的选区集合
    public let beforeSelections: EditorSelectionSet
    /// 变更后的选区集合
    public let afterSelections: EditorSelectionSet
    /// 命令时间戳
    public let timestamp: Date
    /// 每个 mutation 对应的原始文本（用于 undo 回放时恢复，与 mutations 一一对应）
    public let replacedTexts: [String]

    public init(
        mutations: [EditorTextMutation],
        beforeSelections: EditorSelectionSet,
        afterSelections: EditorSelectionSet,
        timestamp: Date,
        replacedTexts: [String]
    ) {
        precondition(mutations.count == replacedTexts.count,
                     "mutations 与 replacedTexts 数量必须一致")
        // 按 location 降序排列，保证应用时不产生偏移串扰
        let indexed = zip(mutations, replacedTexts)
            .sorted { $0.0.rangeLocation > $1.0.rangeLocation }
        self.mutations = indexed.map { $0.0 }
        self.replacedTexts = indexed.map { $0.1 }
        self.beforeSelections = beforeSelections
        self.afterSelections = afterSelections
        self.timestamp = timestamp
    }

    /// 兼容单 mutation 构造器（保持旧调用点不变）
    public init(
        mutation: EditorTextMutation,
        beforeSelection: EditorSelectionSnapshot,
        afterSelection: EditorSelectionSnapshot,
        timestamp: Date,
        replacedText: String
    ) {
        self.init(
            mutations: [mutation],
            beforeSelections: .single(beforeSelection),
            afterSelections: .single(afterSelection),
            timestamp: timestamp,
            replacedTexts: [replacedText]
        )
    }

    // MARK: - 兼容单 mutation 访问器

    /// 首个 mutation（兼容单 mutation 场景）
    public var mutation: EditorTextMutation { mutations[0] }
    /// 变更前的主选区快照
    public var beforeSelection: EditorSelectionSnapshot { beforeSelections.primarySnapshot }
    /// 变更后的主选区快照
    public var afterSelection: EditorSelectionSnapshot { afterSelections.primarySnapshot }
    /// 首个 mutation 对应的原始文本
    public var replacedText: String { replacedTexts[0] }
    /// 是否为单 mutation 命令
    public var isSingleMutation: Bool { mutations.count == 1 }
}

// MARK: - 历史状态

/// 单个文档的编辑历史状态（值类型，按 EditorDocumentKey 隔离存储）
public struct EditorUndoHistoryState: Equatable, Sendable {
    /// 撤销栈（栈顶在末尾）
    public var undoStack: [EditorEditCommand]
    /// 重做栈（栈顶在末尾）
    public var redoStack: [EditorEditCommand]

    public init(undoStack: [EditorEditCommand] = [], redoStack: [EditorEditCommand] = []) {
        self.undoStack = undoStack
        self.redoStack = redoStack
    }

    /// 空历史
    public static let empty = EditorUndoHistoryState()
}

// MARK: - 历史配置

/// 编辑历史配置（默认值固定，集中管理）
public struct EditorUndoHistoryConfiguration: Equatable, Sendable {
    /// 每文档最大历史深度
    public let maxDepth: Int
    /// 连续输入合并窗口（毫秒）
    public let coalescingWindowMs: Int

    public init(maxDepth: Int = 256, coalescingWindowMs: Int = 600) {
        self.maxDepth = maxDepth
        self.coalescingWindowMs = coalescingWindowMs
    }

    /// 默认配置
    public static let `default` = EditorUndoHistoryConfiguration()
}

// MARK: - 历史操作结果

/// 撤销/重做/记录操作的结果
public struct EditorHistoryApplyResult: Equatable, Sendable {
    /// 操作后的文本
    public let text: String
    /// 操作后应恢复的选区集合
    public let selections: EditorSelectionSet
    /// 操作后的历史状态
    public let history: EditorUndoHistoryState
    /// 是否可撤销
    public let canUndo: Bool
    /// 是否可重做
    public let canRedo: Bool

    public init(
        text: String,
        selections: EditorSelectionSet,
        history: EditorUndoHistoryState,
        canUndo: Bool,
        canRedo: Bool
    ) {
        self.text = text
        self.selections = selections
        self.history = history
        self.canUndo = canUndo
        self.canRedo = canRedo
    }

    /// 兼容旧接口：返回主选区快照
    public var selection: EditorSelectionSnapshot { selections.primarySnapshot }
}

// MARK: - 编辑历史语义引擎（纯函数）

/// 编辑历史语义引擎，所有方法为纯函数/静态方法，无副作用。
public enum EditorUndoHistorySemantics {

    // MARK: - 记录编辑

    /// 记录一次编辑命令到历史栈。
    ///
    /// - 清空 redo 栈
    /// - 尝试与栈顶命令合并（满足合并条件时）
    /// - 超出 maxDepth 时裁剪最旧记录
    ///
    /// - Parameters:
    ///   - currentText: 编辑前的文本
    ///   - history: 当前历史状态
    ///   - command: 本次编辑命令
    ///   - configuration: 历史配置
    /// - Returns: 记录后的结果（文本不变，选区为命令 afterSelection）
    public static func recordEdit(
        currentText: String,
        history: EditorUndoHistoryState,
        command: EditorEditCommand,
        configuration: EditorUndoHistoryConfiguration = .default
    ) -> EditorHistoryApplyResult {
        var newHistory = history
        // 记录新编辑时清空 redo 栈
        newHistory.redoStack.removeAll()

        // 只对单 mutation 命令尝试合并（批量命令不合并）
        if command.isSingleMutation,
           let lastCommand = newHistory.undoStack.last,
           lastCommand.isSingleMutation,
           canCoalesce(lastCommand, with: command, configuration: configuration) {
            let merged = coalesce(lastCommand, with: command)
            newHistory.undoStack[newHistory.undoStack.count - 1] = merged
        } else {
            newHistory.undoStack.append(command)
        }

        // 超出深度上限时裁剪最旧记录
        if newHistory.undoStack.count > configuration.maxDepth {
            let overflow = newHistory.undoStack.count - configuration.maxDepth
            newHistory.undoStack.removeFirst(overflow)
        }

        // 应用所有 mutations 得到新文本
        let newText = applyMutations(to: currentText, mutations: command.mutations)

        return EditorHistoryApplyResult(
            text: newText,
            selections: command.afterSelections,
            history: newHistory,
            canUndo: !newHistory.undoStack.isEmpty,
            canRedo: !newHistory.redoStack.isEmpty
        )
    }

    // MARK: - 撤销

    /// 执行撤销操作。
    ///
    /// - Parameters:
    ///   - currentText: 当前文本
    ///   - history: 当前历史状态
    /// - Returns: 撤销结果；栈为空时返回 nil
    public static func undo(
        currentText: String,
        history: EditorUndoHistoryState
    ) -> EditorHistoryApplyResult? {
        guard !history.undoStack.isEmpty else { return nil }
        var newHistory = history
        let command = newHistory.undoStack.removeLast()

        // 反向应用：逆序遍历 mutations（从低位到高位），用 replacedText 恢复
        var restoredText = currentText
        for i in (0..<command.mutations.count).reversed() {
            let mut = command.mutations[i]
            let inverseMutation = EditorTextMutation(
                rangeLocation: mut.rangeLocation,
                rangeLength: (mut.replacementText as NSString).length,
                replacementText: command.replacedTexts[i]
            )
            restoredText = applyMutation(to: restoredText, mutation: inverseMutation)
        }
        newHistory.redoStack.append(command)

        return EditorHistoryApplyResult(
            text: restoredText,
            selections: command.beforeSelections,
            history: newHistory,
            canUndo: !newHistory.undoStack.isEmpty,
            canRedo: !newHistory.redoStack.isEmpty
        )
    }

    // MARK: - 重做

    /// 执行重做操作。
    ///
    /// - Parameters:
    ///   - currentText: 当前文本
    ///   - history: 当前历史状态
    /// - Returns: 重做结果；栈为空时返回 nil
    public static func redo(
        currentText: String,
        history: EditorUndoHistoryState
    ) -> EditorHistoryApplyResult? {
        guard !history.redoStack.isEmpty else { return nil }
        var newHistory = history
        let command = newHistory.redoStack.removeLast()

        let newText = applyMutations(to: currentText, mutations: command.mutations)
        newHistory.undoStack.append(command)

        return EditorHistoryApplyResult(
            text: newText,
            selections: command.afterSelections,
            history: newHistory,
            canUndo: !newHistory.undoStack.isEmpty,
            canRedo: !newHistory.redoStack.isEmpty
        )
    }

    // MARK: - 重置

    /// 重置历史（清空 undo/redo 栈）
    public static func reset(history: EditorUndoHistoryState) -> EditorUndoHistoryState {
        return .empty
    }

    // MARK: - 文档键迁移

    /// 迁移历史状态（另存为/重命名时）。
    /// 历史内容保持不变，仅由调用方在容器层将旧 key 的状态移到新 key。
    /// 返回值等于输入（历史栈不变）。
    public static func migrate(
        history: EditorUndoHistoryState,
        from _: EditorDocumentKey,
        to _: EditorDocumentKey
    ) -> EditorUndoHistoryState {
        return history
    }

    // MARK: - 内部辅助方法

    /// 将单个 mutation 应用到文本
    static func applyMutation(to text: String, mutation: EditorTextMutation) -> String {
        let nsText = text as NSString
        let range = NSRange(location: mutation.rangeLocation, length: mutation.rangeLength)
        return nsText.replacingCharacters(in: range, with: mutation.replacementText)
    }

    /// 批量应用 mutations 到文本。
    /// mutations 须按 rangeLocation 降序排列（从后向前应用，避免偏移失效）。
    static func applyMutations(to text: String, mutations: [EditorTextMutation]) -> String {
        var result = text
        for mutation in mutations {
            result = applyMutation(to: result, mutation: mutation)
        }
        return result
    }

    /// 判断两条命令是否可合并
    static func canCoalesce(
        _ prev: EditorEditCommand,
        with next: EditorEditCommand,
        configuration: EditorUndoHistoryConfiguration
    ) -> Bool {
        // 时间窗口检查
        let timeDiffMs = next.timestamp.timeIntervalSince(prev.timestamp) * 1000
        guard timeDiffMs >= 0, timeDiffMs <= Double(configuration.coalescingWindowMs) else { return false }

        let prevMut = prev.mutation
        let nextMut = next.mutation

        // 类型一致性检查：只合并同类操作
        let prevIsInsert = prevMut.rangeLength == 0 && !prevMut.replacementText.isEmpty
        let nextIsInsert = nextMut.rangeLength == 0 && !nextMut.replacementText.isEmpty
        let prevIsDelete = !prevMut.replacementText.isEmpty == false && prevMut.rangeLength > 0
        let nextIsDelete = nextMut.replacementText.isEmpty && nextMut.rangeLength > 0

        // 单字符检查：只合并单字符输入或单字符删除
        if prevIsInsert && nextIsInsert {
            guard (prevMut.replacementText as NSString).length == 1,
                  (nextMut.replacementText as NSString).length == 1 else { return false }
            // 连续插入：新插入位置 = 上条插入位置 + 上条插入文本长度
            let expectedLocation = prevMut.rangeLocation + (prevMut.replacementText as NSString).length
            return nextMut.rangeLocation == expectedLocation
        }

        if prevIsDelete && nextIsDelete {
            guard prevMut.rangeLength == 1, nextMut.rangeLength == 1 else { return false }
            // 连续退格：新删除位置 = 上条删除位置 - 1（退格）或相同位置（前删）
            return nextMut.rangeLocation == prevMut.rangeLocation - 1
                || nextMut.rangeLocation == prevMut.rangeLocation
        }

        return false
    }

    /// 合并两条命令（调用前必须确认 canCoalesce 为 true）
    static func coalesce(
        _ prev: EditorEditCommand,
        with next: EditorEditCommand
    ) -> EditorEditCommand {
        let prevMut = prev.mutation
        let nextMut = next.mutation

        let prevIsInsert = prevMut.rangeLength == 0 && !prevMut.replacementText.isEmpty
        let nextIsInsert = nextMut.rangeLength == 0 && !nextMut.replacementText.isEmpty

        if prevIsInsert && nextIsInsert {
            // 合并连续插入：区间起始不变，文本拼接
            let mergedMutation = EditorTextMutation(
                rangeLocation: prevMut.rangeLocation,
                rangeLength: 0,
                replacementText: prevMut.replacementText + nextMut.replacementText
            )
            return EditorEditCommand(
                mutation: mergedMutation,
                beforeSelection: prev.beforeSelection,
                afterSelection: next.afterSelection,
                timestamp: next.timestamp,
                replacedText: prev.replacedText
            )
        } else {
            // 合并连续删除
            if nextMut.rangeLocation == prevMut.rangeLocation - 1 {
                // 退格方向：新删除在前
                let mergedMutation = EditorTextMutation(
                    rangeLocation: nextMut.rangeLocation,
                    rangeLength: prevMut.rangeLength + nextMut.rangeLength,
                    replacementText: ""
                )
                return EditorEditCommand(
                    mutation: mergedMutation,
                    beforeSelection: prev.beforeSelection,
                    afterSelection: next.afterSelection,
                    timestamp: next.timestamp,
                    replacedText: next.replacedText + prev.replacedText
                )
            } else {
                // 前删方向（Delete 键）：位置不变
                let mergedMutation = EditorTextMutation(
                    rangeLocation: prevMut.rangeLocation,
                    rangeLength: prevMut.rangeLength + nextMut.rangeLength,
                    replacementText: ""
                )
                return EditorEditCommand(
                    mutation: mergedMutation,
                    beforeSelection: prev.beforeSelection,
                    afterSelection: next.afterSelection,
                    timestamp: next.timestamp,
                    replacedText: prev.replacedText + next.replacedText
                )
            }
        }
    }
}
