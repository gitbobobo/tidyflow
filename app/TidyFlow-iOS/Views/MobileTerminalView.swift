import SwiftUI

/// 工作区级终端壳层容器
///
/// 进入此视图后展示当前工作区的所有活跃终端标签；支持新建、切换、关闭操作。
/// 离开页面只 detach 当前终端，不隐式 close。
struct MobileTerminalView: View {
    @EnvironmentObject var appState: MobileAppState
    let project: String
    let workspace: String
    /// 附着已有终端的 ID（nil 表示新建终端或选中最近活跃）
    var termId: String? = nil
    /// 创建后自动执行的命令
    var command: String? = nil
    /// 命令图标（用于终端列表展示）
    var commandIcon: String? = nil
    /// 命令名称（用于终端列表展示）
    var commandName: String? = nil
    @StateObject private var perfFixtureRunner = TerminalPerfFixtureRunner()

    private var perfFixtureScenario: TerminalPerfFixtureScenario? {
        TerminalPerfFixtureScenario.current()
    }

    /// 当前工作区活跃终端列表
    private var workspaceTerminals: [TerminalSessionInfo] {
        appState.terminalsForWorkspace(project: project, workspace: workspace)
    }

    /// 当前选中的 termId
    private var selectedTermId: String {
        appState.currentTermId
    }

    /// 是否处于空态（无活跃终端且未选中）
    private var isEmpty: Bool {
        workspaceTerminals.isEmpty && appState.currentTermId.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // 横向标签栏（仅在有终端时展示）
            if !workspaceTerminals.isEmpty {
                terminalTabBar
            }

            // 终端内容区
            if isEmpty {
                emptyStateView
            } else {
                terminalContentView
            }
        }
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                let wsId = CoordinatorWorkspaceId(project: project, workspace: workspace)
                let aiStatus = TerminalSessionSemantics.terminalAIStatus(
                    fromCache: appState.coordinatorStateCache,
                    workspaceId: wsId
                )
                if aiStatus.isVisible {
                    Label(aiStatus.hint, systemImage: aiStatus.iconName)
                        .labelStyle(.iconOnly)
                        .foregroundColor(aiStatus.color)
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityLabel(aiStatus.hint)
                }
            }
        }
        .onAppear {
            appState.selectWorkspaceContext(project: project, workspace: workspace)
            if let termId {
                appState.attachTerminal(project: project, workspace: workspace, termId: termId)
            } else if let command {
                appState.createTerminalWithCommand(
                    project: project,
                    workspace: workspace,
                    command: command,
                    icon: commandIcon,
                    name: commandName
                )
            } else {
                // 默认选中工作区上次活跃终端；若无则创建新终端
                let wsTerminals = workspaceTerminals
                if let lastActive = wsTerminals.first {
                    appState.attachTerminal(project: project, workspace: workspace, termId: lastActive.termId)
                } else {
                    appState.createTerminalForWorkspace(project: project, workspace: workspace)
                }
            }
        }
        .onDisappear {
            perfFixtureRunner.cancel()
            appState.detachTerminal()
        }
        .accessibilityIdentifier("tf.ios.terminal.container")
        .overlay(alignment: .topLeading) {
            if perfFixtureScenario != nil {
                ZStack(alignment: .topLeading) {
                    Text("fixture \(perfFixtureRunner.statusText)")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .accessibilityIdentifier("tf.perf.terminal.status")
                    if perfFixtureRunner.isCompleted {
                        Text("fixture completed")
                            .font(.caption2)
                            .opacity(0.01)
                            .accessibilityIdentifier("tf.perf.terminal.completed")
                    }
                }
                .padding(12)
            }
        }
        .task(id: perfFixtureScenario?.id) {
            guard perfFixtureScenario != nil else { return }
            perfFixtureRunner.run(perfReporter: appState.perfReporter)
        }
    }

    // MARK: - 标签栏

    private var terminalTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspaceTerminals, id: \.termId) { terminal in
                        terminalTab(for: terminal)
                            .id(terminal.termId)
                    }
                    // 新建终端按钮
                    Button {
                        appState.createTerminalForWorkspace(project: project, workspace: workspace)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("新建终端")
                    .accessibilityIdentifier("tf.ios.terminal.tab.new")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Color(red: 24/255, green: 24/255, blue: 24/255))
            .onChange(of: selectedTermId) { newId in
                if !newId.isEmpty {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
    }

    private func terminalTab(for terminal: TerminalSessionInfo) -> some View {
        let isSelected = terminal.termId == selectedTermId
        let displayInfo = appState.terminalSessionStore.displayInfo(for: terminal.termId)
        let title = displayInfo?.name ?? String(terminal.termId.prefix(8))
        let iconName = displayInfo?.icon ?? "terminal"

        return Button {
            if !isSelected {
                // 切换到该终端：switchToTerminal 会 detach 旧终端，然后请求 attach 新终端
                appState.switchToTerminal(termId: terminal.termId)
                appState.terminalSessionStore.recordAttachRequest(termId: terminal.termId)
                appState.wsClient.requestTermAttach(termId: terminal.termId)
            }
        } label: {
            HStack(spacing: 4) {
                MobileCommandIconView(iconName: iconName, size: 12)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                Button {
                    appState.closeTerminal(termId: terminal.termId)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭终端")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                        ? Color.white.opacity(0.15)
                        : Color.white.opacity(0.05))
            )
            .foregroundColor(isSelected ? .white : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                appState.closeTerminal(termId: terminal.termId)
            } label: {
                Label("关闭终端", systemImage: "xmark.circle")
            }
            Button {
                appState.terminalSessionStore.togglePinned(termId: terminal.termId)
            } label: {
                if appState.terminalSessionStore.isPinned(termId: terminal.termId) {
                    Label("取消置顶", systemImage: "pin.slash")
                } else {
                    Label("置顶", systemImage: "pin")
                }
            }
            Button(role: .destructive) {
                appState.closeTerminalsToRight(
                    project: project,
                    workspace: workspace,
                    termId: terminal.termId
                )
            } label: {
                Label("关闭右侧终端", systemImage: "xmark.circle.fill")
            }
        }
        .accessibilityIdentifier("tf.ios.terminal.tab.\(terminal.termId)")
    }

    // MARK: - 终端内容

    private var terminalContentView: some View {
        GeometryReader { proxy in
            SwiftTermTerminalView(
                appState: appState,
                topSafeAreaInset: proxy.safeAreaInsets.top,
                onKey: { sequence in
                    appState.sendSpecialKey(sequence)
                },
                onCtrlArmedChanged: { armed in
                    appState.setCtrlArmed(armed)
                },
                onPaste: {
                    appState.handlePaste()
                }
            )
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    // MARK: - 空态

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))
            Text("无活跃终端")
                .font(.headline)
                .foregroundColor(.white.opacity(0.5))
            Button {
                appState.createTerminalForWorkspace(project: project, workspace: workspace)
            } label: {
                Label("新建终端", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("tf.ios.terminal.empty.create")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
