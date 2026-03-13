import SwiftUI

/// iOS 端会话列表 Sheet，支持工作区级筛选隔离与状态徽标。
/// - 筛选状态按 project/workspace 作用域存储，不同工作区互不串扰。
/// - 列表行展示与 macOS 对齐的状态语义（running/awaiting_input/success/cancelled/error）。
/// - 打开时仅对当前页可见 session 受控预取状态，避免全量轮询。
struct MobileSessionListSheet: View {
    @EnvironmentObject var appState: MobileAppState
    @Binding var showSessionList: Bool
    let project: String
    let workspace: String
    var onLoadSession: (AISessionInfo) -> Void
    var onCreateNewSession: () -> Void

    /// 本地筛选条件：从工作区作用域读取初始值，变更时同步回写并发起请求。
    @State private var currentFilter: AISessionListFilter = .all
    /// 状态请求限流器：防止重复轮询。
    @State private var statusLimiter = AISessionStatusRequestLimiter()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterPicker
                sessionListContent
            }
            .navigationTitle("会话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showSessionList = false }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        onCreateNewSession()
                        showSessionList = false
                    }) {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("tf.ios.ai.new-session")
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { showSessionList = false }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        onCreateNewSession()
                        showSessionList = false
                    }) {
                        Image(systemName: "plus")
                    }
                }
                #endif
            }
        }
        .onAppear {
            // 恢复本工作区上次筛选条件，不重置为 .all
            currentFilter = appState.sessionListFilter(for: project, workspace: workspace)
            requestSessionList(for: currentFilter)
        }
        .onChange(of: currentFilter) { _, newFilter in
            appState.setSessionListFilter(newFilter, for: project, workspace: workspace)
            requestSessionList(for: newFilter)
        }
        .accessibilityIdentifier("tf.ios.ai.sessions-panel")
    }

    // MARK: - 筛选栏

    private var filterPicker: some View {
        Picker("AI 工具", selection: $currentFilter) {
            ForEach(AISessionListFilter.allOptions) { filter in
                HStack(spacing: 6) {
                    if let iconAssetName = filter.iconAssetName {
                        Image(iconAssetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                    }
                    Text(filter.displayName)
                }
                .tag(filter)
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 列表主体

    @ViewBuilder
    private var sessionListContent: some View {
        let pageState = currentPageState
        let sessions = pageState.sessions
        let displayPhase = AISessionListDisplayPhase.from(
            isLoadingInitial: pageState.isLoadingInitial, sessions: sessions
        )
        switch displayPhase {
        case .loading:
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("加载中…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("暂无会话")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            List {
                ForEach(sessions) { session in
                    Button(action: {
                        onLoadSession(session)
                        showSessionList = false
                    }) {
                        SessionStatusRow(
                            session: session,
                            isSelected: AISessionListSemantics.isSessionSelected(
                                session: session,
                                currentSessionId: appState.aiCurrentSessionId,
                                currentTool: appState.aiChatTool
                            ),
                            status: appState.aiSessionStatus(for: session)
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            appState.deleteAISession(session)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .onAppear {
                        prefetchStatusIfNeeded(for: session)
                    }
                }
                if pageState.isLoadingNextPage || pageState.hasMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .onAppear {
                        _ = appState.loadNextAISessionListPage(for: currentFilter)
                    }
                }
            }
        }
    }

    // MARK: - 受控状态预取

    /// 对当前可见 session 做受控状态预取，最小间隔 30s，避免暴力轮询。
    private func prefetchStatusIfNeeded(for session: AISessionInfo) {
        let key = "\(session.projectName):\(session.workspaceName):\(session.aiTool.rawValue):\(session.id)"
        var limiter = statusLimiter
        guard limiter.shouldRequest(key: key, minInterval: 30) else { return }
        statusLimiter = limiter
        appState.requestAISessionStatus(
            projectName: session.projectName,
            workspaceName: session.workspaceName,
            aiTool: session.aiTool,
            sessionId: session.id
        )
    }

    // MARK: - 辅助

    private var currentPageState: AISessionListPageState {
        guard !project.isEmpty, !workspace.isEmpty else { return .empty() }
        return appState.aiSessionListStore.pageState(
            project: project,
            workspace: workspace,
            filter: currentFilter
        )
    }

    private func requestSessionList(for filter: AISessionListFilter) {
        _ = appState.requestAISessionList(for: filter)
    }
}

// MARK: - 会话行（状态徽标对齐 macOS SessionRow）

/// 单条会话行视图，展示与 macOS 对齐的 running/awaiting_input/success/cancelled/error 语义。
private struct SessionStatusRow: View {
    let session: AISessionInfo
    let isSelected: Bool
    let status: AISessionStatusSnapshot?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .lineLimit(2)
                    .foregroundStyle(Color.primary)

                HStack(spacing: 6) {
                    Image(session.aiTool.iconAssetName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(session.formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            // 状态徽标
            if let status {
                statusBadge(status)
            }

            // 当前会话选中标志
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusBadge(_ status: AISessionStatusSnapshot) -> some View {
        if status.normalizedStatus == "running" {
            ProgressView()
                .controlSize(.mini)
        } else if status.normalizedStatus == "awaiting_input" {
            Image(systemName: "hourglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
        } else if status.normalizedStatus == "success" {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
        } else if status.normalizedStatus == "cancelled" {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if status.isError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
        }
    }
}

