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

// MARK: - 选区快照

/// 编辑命令执行前后的选区记录（UTF-16 offset）
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

/// 历史栈中记录的命令对象
public struct EditorEditCommand: Equatable, Sendable {
    /// 文本变更
    public let mutation: EditorTextMutation
    /// 变更前的选区
    public let beforeSelection: EditorSelectionSnapshot
    /// 变更后的选区
    public let afterSelection: EditorSelectionSnapshot
    /// 命令时间戳
    public let timestamp: Date

    /// 变更前被替换区间原始文本（用于 undo 回放时恢复）
    public let replacedText: String

    public init(
        mutation: EditorTextMutation,
        beforeSelection: EditorSelectionSnapshot,
        afterSelection: EditorSelectionSnapshot,
        timestamp: Date,
        replacedText: String
    ) {
        self.mutation = mutation
        self.beforeSelection = beforeSelection
        self.afterSelection = afterSelection
        self.timestamp = timestamp
        self.replacedText = replacedText
    }
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
    /// 操作后应恢复的选区
    public let selection: EditorSelectionSnapshot
    /// 操作后的历史状态
    public let history: EditorUndoHistoryState
    /// 是否可撤销
    public let canUndo: Bool
    /// 是否可重做
    public let canRedo: Bool

    public init(
        text: String,
        selection: EditorSelectionSnapshot,
        history: EditorUndoHistoryState,
        canUndo: Bool,
        canRedo: Bool
    ) {
        self.text = text
        self.selection = selection
        self.history = history
        self.canUndo = canUndo
        self.canRedo = canRedo
    }
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

        // 尝试与栈顶合并
        if let lastCommand = newHistory.undoStack.last,
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

        // 应用 mutation 得到新文本
        let newText = applyMutation(to: currentText, mutation: command.mutation)

        return EditorHistoryApplyResult(
            text: newText,
            selection: command.afterSelection,
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

        // 反向操作：用 replacedText 恢复到变更前的文本
        let inverseMutation = EditorTextMutation(
            rangeLocation: command.mutation.rangeLocation,
            rangeLength: (command.mutation.replacementText as NSString).length,
            replacementText: command.replacedText
        )
        let restoredText = applyMutation(to: currentText, mutation: inverseMutation)
        newHistory.redoStack.append(command)

        return EditorHistoryApplyResult(
            text: restoredText,
            selection: command.beforeSelection,
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

        let newText = applyMutation(to: currentText, mutation: command.mutation)
        newHistory.undoStack.append(command)

        return EditorHistoryApplyResult(
            text: newText,
            selection: command.afterSelection,
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

    /// 将 mutation 应用到文本
    static func applyMutation(to text: String, mutation: EditorTextMutation) -> String {
        let nsText = text as NSString
        let range = NSRange(location: mutation.rangeLocation, length: mutation.rangeLength)
        return nsText.replacingCharacters(in: range, with: mutation.replacementText)
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
