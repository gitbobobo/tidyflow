#if os(macOS)
import SwiftUI
import Combine

@MainActor
final class AIChatSidebarState: ObservableObject {
    @Published private(set) var filter: AISessionListFilter = .all
    @Published private(set) var pageState: AISessionListPageState = .empty()
    @Published private(set) var currentSessionId: String?
    @Published private(set) var currentTool: AIChatTool = .opencode
    @Published private(set) var sessionStatusesBySessionKey: [String: AISessionStatusSnapshot] = [:]

    private weak var appState: AppState?
    private var cancellables: Set<AnyCancellable> = []
    private var currentStoreCancellable: AnyCancellable?
    private weak var observedStore: AIChatStore?

    func bind(appState: AppState) {
        if self.appState !== appState {
            self.appState = appState
            cancellables.removeAll()
            currentStoreCancellable = nil
            observedStore = nil

            appState.$sessionPanelFilter
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)

            appState.$aiSessionListPageStates
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)

            appState.$selectedProjectName
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)

            appState.$selectedWorkspaceKey
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)

            appState.$aiChatTool
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)

            appState.$aiSessionStatusesByTool
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshSessionStatuses() }
                .store(in: &cancellables)

            appState.$aiChatStore
                .receive(on: DispatchQueue.main)
                .sink { [weak self] store in
                    self?.bindCurrentStore(store)
                    self?.refresh()
                }
                .store(in: &cancellables)
        }

        bindCurrentStore(appState.aiChatStore)
        refresh()
    }

    func sessionStatus(for session: AISessionInfo) -> AISessionStatusSnapshot? {
        sessionStatusesBySessionKey[session.sessionKey]
    }

    private func bindCurrentStore(_ store: AIChatStore) {
        guard observedStore !== store else { return }
        observedStore = store
        currentStoreCancellable = store.$currentSessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] currentSessionId in
                self?.currentSessionId = currentSessionId
            }
    }

    private func refresh() {
        guard let appState else { return }
        filter = appState.sessionPanelFilter
        pageState = appState.displayedAISessionListState
        currentTool = appState.aiChatTool
        currentSessionId = appState.aiChatStore.currentSessionId
        refreshSessionStatuses()
    }

    private func refreshSessionStatuses() {
        guard let appState else { return }
        var statuses: [String: AISessionStatusSnapshot] = [:]
        for session in pageState.sessions {
            if let status = appState.aiSessionStatus(for: session) {
                statuses[session.sessionKey] = status
            }
        }
        sessionStatusesBySessionKey = statuses
    }
}

/// AI 聊天界面左侧常驻侧边栏，显示会话列表。
/// 通过派生状态对象隔离高频 `AppState` 更新，避免无关发布导致整个侧栏重算。
struct AIChatSidebarView: View {
    @ObservedObject var state: AIChatSidebarState
    var width: CGFloat = 260

    var onSelect: (AISessionInfo) -> Void
    var onDelete: (AISessionInfo) -> Void
    var onRename: (AISessionInfo) -> Void
    var onFilterChange: (AISessionListFilter) -> Void
    var onRequestSessionList: (AISessionListFilter) -> Void
    var onLoadNextPage: (AISessionListFilter) -> Void

    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(AISessionListFilter.allOptions) { filter in
                        Button(action: {
                            onFilterChange(filter)
                        }) {
                            Label {
                                Text(filter.displayName)
                            } icon: {
                                if let iconAssetName = filter.iconAssetName {
                                    FixedSizeAssetImage(name: iconAssetName, targetSize: 16)
                                } else {
                                    Image(systemName: "square.stack.3d.up")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let iconAssetName = state.filter.iconAssetName {
                            FixedSizeAssetImage(name: iconAssetName, targetSize: 16)
                        } else {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(state.filter.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索会话…", text: $searchText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider()

            let pageState = state.pageState
            let allSessions = pageState.sessions
            let sessions: [AISessionInfo] = searchText.isEmpty
                ? allSessions
                : allSessions.filter { $0.title.localizedStandardContains(searchText) }
            let isLoadingSessions = pageState.isLoadingInitial
            if isLoadingSessions && sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("加载中…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("暂无会话")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: session.id == state.currentSessionId && session.aiTool == state.currentTool,
                            status: state.sessionStatus(for: session)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(session)
                        }
                        .contextMenu {
                            Button {
                                onRename(session)
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                onDelete(session)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                    if pageState.isLoadingNextPage || pageState.hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .onAppear {
                            if searchText.isEmpty {
                                onLoadNextPage(state.filter)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: width)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .onAppear {
            onFilterChange(.all)
            onRequestSessionList(.all)
        }
        .onChange(of: state.filter) { _, newFilter in
            onRequestSessionList(newFilter)
        }
    }
}

#Preview {
    AIChatSidebarView(
        state: AIChatSidebarState(),
        onSelect: { _ in },
        onDelete: { _ in },
        onRename: { _ in },
        onFilterChange: { _ in },
        onRequestSessionList: { _ in },
        onLoadNextPage: { _ in }
    )
    .frame(height: 500)
}
#endif
