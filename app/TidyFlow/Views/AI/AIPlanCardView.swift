import SwiftUI

struct AIPlanEntryItem: Equatable, Identifiable {
    let id: String
    let content: String
    let status: String
    let priority: String?

    private var normalizedStatus: String {
        status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var displayStatus: String {
        switch normalizedStatus {
        case "pending":
            return "待办"
        case "in_progress":
            return "进行中"
        case "completed":
            return "已完成"
        default:
            return status.isEmpty ? "unknown" : status
        }
    }

    var displayPriority: String? {
        let token = priority?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !token.isEmpty else { return nil }
        switch token {
        case "high":
            return "高"
        case "medium":
            return "中"
        case "low":
            return "低"
        default:
            return priority
        }
    }

    var statusTint: Color {
        switch normalizedStatus {
        case "pending":
            return .orange
        case "in_progress":
            return .blue
        case "completed":
            return .green
        default:
            return .secondary
        }
    }
}

struct AIPlanSnapshotItem: Equatable, Identifiable {
    let id: String
    let revision: Int?
    let updatedAtMs: Int64?
    let entries: [AIPlanEntryItem]

    var revisionLabel: String {
        if let revision {
            return "v\(revision)"
        }
        return "v-"
    }
}

struct AIPlanCardPayload: Equatable {
    let revision: Int?
    let updatedAtMs: Int64?
    let entries: [AIPlanEntryItem]
    let history: [AIPlanSnapshotItem]

    var summaryLine: String {
        if let revision {
            return "[计划] \(entries.count) 项 · v\(revision)"
        }
        return "[计划] \(entries.count) 项"
    }

    static func from(source: [String: Any]?) -> AIPlanCardPayload? {
        guard let source else { return nil }
        guard let entriesRaw = source["entries"] as? [Any] else { return nil }

        let entries = parseEntries(entriesRaw)
        let revision = parseInt(source["revision"])
        let updatedAtMs = parseInt64(source["updated_at_ms"])

        let historyRaw = source["history"] as? [Any] ?? []
        let history = historyRaw.compactMap { item -> AIPlanSnapshotItem? in
            guard let dict = item as? [String: Any] else { return nil }
            guard let historyEntriesRaw = dict["entries"] as? [Any] else { return nil }
            let historyEntries = parseEntries(historyEntriesRaw)
            let historyRevision = parseInt(dict["revision"])
            let historyUpdatedAtMs = parseInt64(dict["updated_at_ms"])
            let id = "\(historyRevision ?? -1)-\(historyUpdatedAtMs ?? -1)-\(historyEntries.count)"
            return AIPlanSnapshotItem(
                id: id,
                revision: historyRevision,
                updatedAtMs: historyUpdatedAtMs,
                entries: historyEntries
            )
        }

        return AIPlanCardPayload(
            revision: revision,
            updatedAtMs: updatedAtMs,
            entries: entries,
            history: history
        )
    }

    private static func parseEntries(_ values: [Any]) -> [AIPlanEntryItem] {
        values.enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            let content = (dict["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = (dict["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty, !status.isEmpty else { return nil }
            let priority = (dict["priority"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AIPlanEntryItem(
                id: "\(index)-\(content)-\(status)-\(priority ?? "")",
                content: content,
                status: status,
                priority: priority?.isEmpty == true ? nil : priority
            )
        }
    }

    private static func parseInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let int64Value = parseInt64(value), int64Value <= Int64(Int.max), int64Value >= Int64(Int.min) {
            return Int(int64Value)
        }
        return nil
    }

    private static func parseInt64(_ value: Any?) -> Int64? {
        switch value {
        case let intValue as Int:
            return Int64(intValue)
        case let int64Value as Int64:
            return int64Value
        case let number as NSNumber:
            return number.int64Value
        case let text as String:
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

struct AIPlanCardView: View {
    let part: AIChatPart

    private var payload: AIPlanCardPayload? {
        AIPlanCardPayload.from(source: part.source)
    }

    var body: some View {
        Group {
            if let payload {
                VStack(alignment: .leading, spacing: 10) {
                    header(payload: payload)
                    currentEntries(payload: payload)
                    if !payload.history.isEmpty {
                        historySection(payload: payload)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
            } else {
                Text("计划数据不可用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func header(payload: AIPlanCardPayload) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("当前计划")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(payload.summaryLine.replacingOccurrences(of: "[计划] ", with: ""))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func currentEntries(payload: AIPlanCardPayload) -> some View {
        if payload.entries.isEmpty {
            Text("当前计划为空")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(payload.entries) { entry in
                    planEntryRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func historySection(payload: AIPlanCardPayload) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(payload.history.reversed()) { snapshot in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.revisionLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if snapshot.entries.isEmpty {
                            Text("当前计划为空")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(snapshot.entries) { entry in
                                planEntryRow(entry)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 4)
        } label: {
            Text("历史版本（\(payload.history.count)）")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func planEntryRow(_ entry: AIPlanEntryItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.displayStatus)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(entry.statusTint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(entry.statusTint.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let priority = entry.displayPriority {
                    Text("优先级：\(priority)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
