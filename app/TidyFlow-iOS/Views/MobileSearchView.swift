import SwiftUI
import TidyFlowShared

/// iOS 工作区级全局搜索页面
/// 复用 TidyFlowShared 共享搜索状态与结果模型
struct MobileSearchView: View {
    let appState: MobileAppState
    let project: String
    let workspace: String

    @State private var searchText: String = ""
    @State private var caseSensitive: Bool = false

    private var globalKey: String {
        appState.globalWorkspaceKey(project: project, workspace: workspace)
    }

    private var searchState: GlobalSearchState {
        appState.globalSearchStates[globalKey] ?? .empty()
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            resultContent
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 恢复上次查询词
            if !searchState.query.isEmpty {
                searchText = searchState.query.text
                caseSensitive = searchState.query.caseSensitive
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索文件内容…", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        appState.performGlobalSearch(
                            project: project,
                            workspace: workspace,
                            query: searchText,
                            caseSensitive: caseSensitive
                        )
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        appState.performGlobalSearch(project: project, workspace: workspace, query: "")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .cornerRadius(10)

            HStack {
                Button {
                    caseSensitive.toggle()
                } label: {
                    Text("Aa")
                        .font(.system(size: 14, weight: caseSensitive ? .bold : .regular, design: .monospaced))
                        .foregroundColor(caseSensitive ? .accentColor : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(caseSensitive ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(6)
                }

                Spacer()

                if searchState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if searchState.hasResults {
                    Text("\(searchState.totalMatches) 个匹配")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if searchState.truncated {
                        Text("（已截断）")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 结果区

    @ViewBuilder
    private var resultContent: some View {
        if let error = searchState.error {
            ContentUnavailableView {
                Label("搜索出错", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if searchState.isLoading && !searchState.hasResults {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("搜索中…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else if searchState.hasResults {
            resultList
        } else if !searchState.query.isEmpty {
            ContentUnavailableView.search(text: searchState.query.text)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("输入关键词搜索工作区文件内容")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - 结果列表

    private var resultList: some View {
        List {
            ForEach(searchState.sections) { section in
                Section {
                    ForEach(section.matches) { match in
                        NavigationLink(
                            value: MobileRoute.workspaceEditor(
                                project: project,
                                workspace: workspace,
                                path: match.path
                            )
                        ) {
                            MobileSearchMatchRow(match: match)
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                        Text(section.fileName)
                            .font(.system(size: 13, weight: .medium))
                        if !section.directoryPath.isEmpty {
                            Text(section.directoryPath)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(section.matchCount)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 匹配行视图

private struct MobileSearchMatchRow: View {
    let match: GlobalSearchMatch

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("L\(match.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 36, alignment: .trailing)

            highlightedPreview
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var highlightedPreview: Text {
        let segments = GlobalSearchPreviewFormatter.highlightedSegments(
            preview: match.preview,
            matchRanges: match.matchRanges
        )
        return segments.reduce(Text("")) { result, segment in
            if segment.isHighlighted {
                return result + Text(segment.text)
                    .foregroundColor(.accentColor)
                    .bold()
            } else {
                return result + Text(segment.text)
                    .foregroundColor(.primary)
            }
        }
    }
}
