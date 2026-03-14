import Foundation

// MARK: - 编辑器格式化共享语义层
//
// 此文件属于 TidyFlowShared，不依赖 SwiftUI、AppKit 或 UIKit。
// 定义跨 macOS/iOS 共享的格式化类型、请求构建、结果回放规则。
//
// 设计约束：
// - 语义层不做文本猜测式范围格式化，仅消费 Core 权威返回。
// - 一次格式化视为单条可撤销命令。
// - 格式化状态（isFormatting / lastFormattingError / supportedFormattingScopes）
//   由文档会话投影，是共享真源。

// MARK: - 格式化作用域

/// 格式化作用域（与 Core EditorFormatScope 对齐）
public enum EditorFormatScope: String, Codable, Equatable, Sendable {
    /// 整文档格式化
    case document
    /// 选区格式化
    case selection
}

// MARK: - 格式化错误码

/// 格式化错误码（与 Core EditorFormattingErrorCode 对齐）
public enum EditorFormattingErrorCode: String, Codable, Equatable, Sendable {
    case unsupportedLanguage = "unsupported_language"
    case toolUnavailable = "tool_unavailable"
    case unsupportedScope = "unsupported_scope"
    case workspaceUnavailable = "workspace_unavailable"
    case executionFailed = "execution_failed"
    case invalidRequest = "invalid_request"
}

// MARK: - 格式化能力

/// 单个格式化器的能力声明（与 Core EditorFormattingCapability 对齐）
public struct EditorFormattingCapability: Codable, Equatable, Sendable {
    public let formatterId: String
    public let language: String
    public let supportedScopes: [EditorFormatScope]

    public init(formatterId: String, language: String, supportedScopes: [EditorFormatScope]) {
        self.formatterId = formatterId
        self.language = language
        self.supportedScopes = supportedScopes
    }

    enum CodingKeys: String, CodingKey {
        case formatterId = "formatter_id"
        case language
        case supportedScopes = "supported_scopes"
    }
}

// MARK: - 格式化请求上下文

/// 格式化请求上下文，从 EditorDocumentSession 构建
public struct EditorFormattingRequestContext: Equatable, Sendable {
    public let project: String
    public let workspace: String
    public let path: String
    public let scope: EditorFormatScope
    public let text: String
    public let selectionStart: Int?
    public let selectionEnd: Int?

    public init(
        project: String,
        workspace: String,
        path: String,
        scope: EditorFormatScope,
        text: String,
        selectionStart: Int? = nil,
        selectionEnd: Int? = nil
    ) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.scope = scope
        self.text = text
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
    }
}

// MARK: - 格式化结果

/// 格式化结果（从 Core 响应解码）
public struct EditorFormattingResult: Equatable, Sendable {
    public let project: String
    public let workspace: String
    public let path: String
    public let formattedText: String
    public let formatterId: String
    public let scope: EditorFormatScope
    public let changed: Bool

    public init(
        project: String,
        workspace: String,
        path: String,
        formattedText: String,
        formatterId: String,
        scope: EditorFormatScope,
        changed: Bool
    ) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.formattedText = formattedText
        self.formatterId = formatterId
        self.scope = scope
        self.changed = changed
    }
}

// MARK: - 格式化错误

/// 格式化错误（从 Core 错误响应解码）
public struct EditorFormattingError: Equatable, Sendable {
    public let project: String
    public let workspace: String
    public let path: String
    public let errorCode: EditorFormattingErrorCode
    public let message: String?

    public init(
        project: String,
        workspace: String,
        path: String,
        errorCode: EditorFormattingErrorCode,
        message: String? = nil
    ) {
        self.project = project
        self.workspace = workspace
        self.path = path
        self.errorCode = errorCode
        self.message = message
    }
}

// MARK: - 语言级格式化配置

/// 语言级格式化配置（与 Core EditorFormattingLanguageConfig 对齐）
public struct EditorFormattingLanguageConfig: Codable, Equatable, Sendable {
    public var language: String
    public var preferredFormatterId: String?
    public var formatOnSave: Bool
    public var allowFullDocumentFallback: Bool
    public var extraArgs: [String]

    public init(
        language: String,
        preferredFormatterId: String? = nil,
        formatOnSave: Bool = false,
        allowFullDocumentFallback: Bool = false,
        extraArgs: [String] = []
    ) {
        self.language = language
        self.preferredFormatterId = preferredFormatterId
        self.formatOnSave = formatOnSave
        self.allowFullDocumentFallback = allowFullDocumentFallback
        self.extraArgs = extraArgs
    }

    enum CodingKeys: String, CodingKey {
        case language
        case preferredFormatterId = "preferred_formatter_id"
        case formatOnSave = "format_on_save"
        case allowFullDocumentFallback = "allow_full_document_fallback"
        case extraArgs = "extra_args"
    }
}

// MARK: - 格式化运行时状态

/// 文档格式化运行时状态投影
public struct EditorFormattingState: Equatable, Sendable {
    /// 是否正在执行格式化
    public var isFormatting: Bool
    /// 最近一次格式化错误
    public var lastFormattingError: EditorFormattingError?
    /// 当前文档支持的格式化作用域
    public var supportedFormattingScopes: [EditorFormatScope]

    public init(
        isFormatting: Bool = false,
        lastFormattingError: EditorFormattingError? = nil,
        supportedFormattingScopes: [EditorFormatScope] = []
    ) {
        self.isFormatting = isFormatting
        self.lastFormattingError = lastFormattingError
        self.supportedFormattingScopes = supportedFormattingScopes
    }

    /// 初始状态
    public static let idle = EditorFormattingState()
}

// MARK: - 请求构建

/// 格式化请求构建：从 EditorDocumentSession 生成请求上下文
public enum EditorFormattingRequestBuilder {

    /// 从文档会话构建整文档格式化请求
    public static func buildDocumentRequest(
        session: EditorDocumentSession
    ) -> EditorFormattingRequestContext {
        EditorFormattingRequestContext(
            project: session.key.project,
            workspace: session.key.workspace,
            path: session.key.path,
            scope: .document,
            text: session.content
        )
    }

    /// 从文档会话和选区构建选区格式化请求
    public static func buildSelectionRequest(
        session: EditorDocumentSession
    ) -> EditorFormattingRequestContext? {
        let primary = session.selectionSet.primarySelection
        guard primary.length > 0 else { return nil }
        return EditorFormattingRequestContext(
            project: session.key.project,
            workspace: session.key.workspace,
            path: session.key.path,
            scope: .selection,
            text: session.content,
            selectionStart: primary.location,
            selectionEnd: primary.endLocation
        )
    }
}

// MARK: - 结果回放

/// 格式化结果回放：将 Core 返回映射为单条可撤销编辑命令
public enum EditorFormattingResultApplier {

    /// 将格式化结果回放到编辑历史，生成单条可撤销编辑命令。
    ///
    /// - Parameters:
    ///   - result: Core 返回的格式化结果
    ///   - currentText: 格式化前的文本（应与发送请求时一致）
    ///   - currentSelections: 格式化前的选区集合
    ///   - history: 当前编辑历史状态
    /// - Returns: 回放后的历史结果；若文本未变化返回 nil
    public static func applyFormatResult(
        result: EditorFormattingResult,
        currentText: String,
        currentSelections: EditorSelectionSet,
        history: EditorUndoHistoryState
    ) -> EditorHistoryApplyResult? {
        guard result.changed else { return nil }

        let formattedText = result.formattedText
        let textLength = (currentText as NSString).length

        // 构建单条 mutation：替换整个文档
        let mutation = EditorTextMutation(
            rangeLocation: 0,
            rangeLength: textLength,
            replacementText: formattedText
        )

        // 格式化后光标归零（文档级格式化后选区无法精确映射，采用安全默认值）
        let formattedLength = (formattedText as NSString).length
        let afterSelections = EditorSelectionSet.single(
            location: min(currentSelections.primarySelection.location, formattedLength),
            length: 0
        )

        let command = EditorEditCommand(
            mutations: [mutation],
            beforeSelections: currentSelections,
            afterSelections: afterSelections,
            timestamp: Date(),
            replacedTexts: [currentText]
        )

        // 直接入栈（不合并），一次格式化就是一条撤销记录
        var newHistory = history
        newHistory.redoStack.removeAll()
        newHistory.undoStack.append(command)

        // 超出深度上限时裁剪最旧记录
        let maxDepth = EditorUndoHistoryConfiguration.default.maxDepth
        if newHistory.undoStack.count > maxDepth {
            let overflow = newHistory.undoStack.count - maxDepth
            newHistory.undoStack.removeFirst(overflow)
        }

        return EditorHistoryApplyResult(
            text: formattedText,
            selections: afterSelections,
            history: newHistory,
            canUndo: !newHistory.undoStack.isEmpty,
            canRedo: !newHistory.redoStack.isEmpty
        )
    }
}
