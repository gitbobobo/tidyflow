import SwiftUI

struct AIChatStageActions {
    let onLoadOlderMessages: (() -> Void)?
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    let onQuestionReplyAsMessage: (String) -> Void
    let onOpenLinkedSession: ((String) -> Void)?
}

struct AIChatStagePlatformChrome {
    let stageBackgroundColor: Color
    let transcriptBackgroundColor: Color
    let composerHorizontalPadding: CGFloat
    let composerBottomPadding: CGFloat
    let composerMinimumReserveHeight: CGFloat
    let accessoryLeadingPadding: CGFloat
    let accessoryBottomSpacing: CGFloat

    #if os(macOS)
    static let macOS = AIChatStagePlatformChrome(
        stageBackgroundColor: Color(NSColor.windowBackgroundColor),
        transcriptBackgroundColor: .clear,
        composerHorizontalPadding: 12,
        composerBottomPadding: 12,
        composerMinimumReserveHeight: 148,
        accessoryLeadingPadding: 12,
        accessoryBottomSpacing: 6
    )
    #endif

    #if os(iOS)
    static let iOS = AIChatStagePlatformChrome(
        stageBackgroundColor: Color(UIColor.systemGroupedBackground),
        transcriptBackgroundColor: Color(UIColor.systemGroupedBackground),
        composerHorizontalPadding: 0,
        composerBottomPadding: 8,
        composerMinimumReserveHeight: 152,
        accessoryLeadingPadding: 0,
        accessoryBottomSpacing: 0
    )
    #endif
}

private struct AIChatStageDockHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AIChatStageView<ComposerContent: View, AccessoryOverlay: View>: View {
    let projection: AIChatShellProjection
    let store: AIChatStore
    @Binding var selectedTool: AIChatTool
    let platformChrome: AIChatStagePlatformChrome
    let actions: AIChatStageActions
    let enablesTranscriptTapDismiss: Bool
    let onTranscriptTap: (() -> Void)?
    @ViewBuilder let composerContent: () -> ComposerContent
    @ViewBuilder let accessoryOverlay: (_ composerHeight: CGFloat) -> AccessoryOverlay

    @State private var floatingComposerHeight: CGFloat = 0

    init(
        projection: AIChatShellProjection,
        store: AIChatStore,
        selectedTool: Binding<AIChatTool>,
        platformChrome: AIChatStagePlatformChrome,
        actions: AIChatStageActions,
        enablesTranscriptTapDismiss: Bool = false,
        onTranscriptTap: (() -> Void)? = nil,
        @ViewBuilder composerContent: @escaping () -> ComposerContent,
        @ViewBuilder accessoryOverlay: @escaping (_ composerHeight: CGFloat) -> AccessoryOverlay
    ) {
        self.projection = projection
        self.store = store
        self._selectedTool = selectedTool
        self.platformChrome = platformChrome
        self.actions = actions
        self.enablesTranscriptTapDismiss = enablesTranscriptTapDismiss
        self.onTranscriptTap = onTranscriptTap
        self.composerContent = composerContent
        self.accessoryOverlay = accessoryOverlay
    }

    private var reservedMessageBottomInset: CGFloat {
        max(floatingComposerHeight, platformChrome.composerMinimumReserveHeight) +
            projection.presentation.bottomDockClearance
    }

    var body: some View {
        AIChatStageContainer(
            projection: projection,
            store: store,
            selectedTool: $selectedTool,
            platformChrome: platformChrome,
            actions: actions,
            reservedMessageBottomInset: reservedMessageBottomInset,
            floatingComposerHeight: floatingComposerHeight,
            enablesTranscriptTapDismiss: enablesTranscriptTapDismiss,
            onTranscriptTap: onTranscriptTap,
            composerContent: composerContent,
            accessoryOverlay: accessoryOverlay
        )
        .background(platformChrome.stageBackgroundColor)
        .onPreferenceChange(AIChatStageDockHeightPreferenceKey.self) { newHeight in
            guard abs(newHeight - floatingComposerHeight) > 0.5 else { return }
            floatingComposerHeight = newHeight
        }
    }
}

extension AIChatStageView where AccessoryOverlay == EmptyView {
    init(
        projection: AIChatShellProjection,
        store: AIChatStore,
        selectedTool: Binding<AIChatTool>,
        platformChrome: AIChatStagePlatformChrome,
        actions: AIChatStageActions,
        enablesTranscriptTapDismiss: Bool = false,
        onTranscriptTap: (() -> Void)? = nil,
        @ViewBuilder composerContent: @escaping () -> ComposerContent
    ) {
        self.init(
            projection: projection,
            store: store,
            selectedTool: selectedTool,
            platformChrome: platformChrome,
            actions: actions,
            enablesTranscriptTapDismiss: enablesTranscriptTapDismiss,
            onTranscriptTap: onTranscriptTap,
            composerContent: composerContent,
            accessoryOverlay: { _ in EmptyView() }
        )
    }
}

private struct AIChatStageContainer<ComposerContent: View, AccessoryOverlay: View>: View {
    let projection: AIChatShellProjection
    let store: AIChatStore
    @Binding var selectedTool: AIChatTool
    let platformChrome: AIChatStagePlatformChrome
    let actions: AIChatStageActions
    let reservedMessageBottomInset: CGFloat
    let floatingComposerHeight: CGFloat
    let enablesTranscriptTapDismiss: Bool
    let onTranscriptTap: (() -> Void)?
    @ViewBuilder let composerContent: () -> ComposerContent
    @ViewBuilder let accessoryOverlay: (_ composerHeight: CGFloat) -> AccessoryOverlay

    private var presentation: AIChatPresentationProjection {
        projection.presentation
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 转录区域宿主：单独提取为子视图，使其对 store.messages 的观察面
            // 隔离于 shell chrome，纯文本 token 增量不会导致 shell 层重算。
            AIChatTranscriptHost(
                store: store,
                presentation: presentation,
                selectedTool: $selectedTool,
                actions: actions,
                reservedMessageBottomInset: reservedMessageBottomInset,
                transcriptBackgroundColor: platformChrome.transcriptBackgroundColor,
                enablesTranscriptTapDismiss: enablesTranscriptTapDismiss,
                onTranscriptTap: onTranscriptTap
            )

            accessoryOverlay(floatingComposerHeight)
                .padding(.leading, platformChrome.accessoryLeadingPadding)
                .padding(.bottom, floatingComposerHeight + platformChrome.accessoryBottomSpacing)

            dockLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var dockLayer: some View {
        composerContent()
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AIChatStageDockHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .padding(.horizontal, platformChrome.composerHorizontalPadding)
            .padding(.bottom, platformChrome.composerBottomPadding)
            .frame(maxWidth: .infinity, alignment: .bottom)
    }
}

// MARK: - AIChatTranscriptHost

/// 转录区域宿主：单独隔离 store.messages 观察面。
///
/// 此视图负责订阅 store.messages 的变化，stage shell chrome 与 composer 不应因
/// 纯文本 token 增量重算整个 AIChatStageContainer。
private struct AIChatTranscriptHost: View {
    let store: AIChatStore
    let presentation: AIChatPresentationProjection
    @Binding var selectedTool: AIChatTool
    let actions: AIChatStageActions
    let reservedMessageBottomInset: CGFloat
    let transcriptBackgroundColor: Color
    let enablesTranscriptTapDismiss: Bool
    let onTranscriptTap: (() -> Void)?

    var body: some View {
        let _ = SwiftUIRenderDiagnostics.recordRender(name: "AIChatTranscriptHost")
        ZStack {
            if presentation.showsEmptyState {
                AIChatEmptyStateView(
                    currentTool: presentation.tool,
                    selectedTool: $selectedTool,
                    canSwitchTool: presentation.canSwitchTool,
                    isLoading: presentation.isLoadingMessages
                )
            } else {
                AIChatTranscriptContainer(
                    messages: store.messages,
                    sessionToken: presentation.currentSessionId,
                    canLoadOlderMessages: presentation.canLoadOlderMessages,
                    isLoadingOlderMessages: presentation.isLoadingOlderMessages,
                    onLoadOlderMessages: actions.onLoadOlderMessages,
                    bottomOverlayInset: reservedMessageBottomInset,
                    jumpToBottomClearance: presentation.jumpToBottomClearance,
                    onQuestionReply: actions.onQuestionReply,
                    onQuestionReject: actions.onQuestionReject,
                    onQuestionReplyAsMessage: actions.onQuestionReplyAsMessage,
                    onOpenLinkedSession: actions.onOpenLinkedSession
                )
                .environment(store)
                .id(presentation.transcriptIdentity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(transcriptBackgroundColor)
        .overlay {
            if enablesTranscriptTapDismiss, let onTranscriptTap {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTranscriptTap)
            }
        }
    }
}
