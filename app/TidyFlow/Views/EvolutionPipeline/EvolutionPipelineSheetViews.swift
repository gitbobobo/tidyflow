import SwiftUI

#if os(macOS)

/// 独立子视图：循环详情弹窗
///
/// 只接收不可变投影数据与关闭/打开会话闭包，不依赖 AppState。
struct EvolutionCycleDetailSheetView: View {
    let payload: PipelineCycleDetailPayload
    var onOpenSession: ((PipelineCycleTimelineEntry, String) -> Void)?
    var onClose: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerSection
                    metaBadgesSection
                    terminalInfoSection
                    Divider()
                    timelineSection
                }
                .padding(16)
            }
            .navigationTitle(String(format: "evolution.page.pipeline.roundLabel".localized, payload.round))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) {
                        onClose()
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    // MARK: - 标题

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 8) {
            roundBadge(round: payload.round, color: .indigo)
            Text(payload.title)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer()
            if let status = trimmedNonEmpty(payload.status) {
                let info = cycleStatusInfo(status)
                Text(info.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(info.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(info.color.opacity(0.12)))
                    .fixedSize()
            }
        }
    }

    // MARK: - 元信息

    private var metaBadgesSection: some View {
        HStack(spacing: 10) {
            detailMetaBadge(
                icon: "clock",
                label: "evolution.page.pipeline.startTimeLabel".localized,
                value: payload.startTimeText
            )
            if let totalDurationText = payload.totalDurationText {
                detailMetaBadge(
                    icon: "timer",
                    label: "evolution.page.pipeline.durationLabel".localized,
                    value: totalDurationText
                )
            }
        }
    }

    // MARK: - 终止信息

    @ViewBuilder
    private var terminalInfoSection: some View {
        if let reason = trimmedNonEmpty(payload.terminalReasonCode) {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(localizedTerminalReason(reason))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        if let error = trimmedNonEmpty(payload.terminalErrorMessage) {
            Text(error)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 时间线

    @ViewBuilder
    private var timelineSection: some View {
        Text("evolution.page.pipeline.timelineTitle".localized)
            .font(.headline)

        if payload.timelineEntries.isEmpty {
            Text("evolution.page.pipeline.noTimeline".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(payload.timelineEntries) { entry in
                    timelineRow(entry)
                }
            }
        }
    }

    private func timelineRow(_ entry: PipelineCycleTimelineEntry) -> some View {
        let canOpen = hasResolvedSession(entry)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: EvolutionStageSemantics.iconName(for: entry.stage))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(EvolutionStageSemantics.stageColor(entry.stage))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(EvolutionStageSemantics.displayName(for: entry.stage))
                        .font(.system(size: 12, weight: .semibold))
                    if let agent = trimmedNonEmpty(entry.agent) {
                        Text(agent)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 10) {
                    detailTimelineText(icon: "clock", value: startTimeText(entry.startedAt))
                    detailTimelineText(icon: "timer", value: durationText(entry))
                    let aiTool = trimmedNonEmpty(entry.aiToolName) ?? "-"
                    detailTimelineText(icon: "sparkles", value: "\("evolution.page.pipeline.aiTool".localized): \(aiTool)")
                }
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if canOpen {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(EvolutionStageSemantics.stageColor(entry.stage).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(EvolutionStageSemantics.stageColor(entry.stage).opacity(0.2), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            guard canOpen else { return }
            onOpenSession?(entry, payload.cycleID)
        }
    }

    // MARK: - 辅助组件

    private func roundBadge(round: Int, color: Color) -> some View {
        Text("\(max(1, round))")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(color.opacity(0.14))
            )
            .overlay(
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1)
            )
    }

    private func detailMetaBadge(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func detailTimelineText(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
    }

    // MARK: - 辅助方法

    private func hasResolvedSession(_ entry: PipelineCycleTimelineEntry) -> Bool {
        trimmedNonEmpty(entry.sessionID) != nil &&
            entry.aiToolRawValue.flatMap(AIChatTool.init(rawValue:)) != nil
    }

    private func startTimeText(_ startedAt: String?) -> String {
        guard let date = EvolutionPipelineDateFormatting.rfc3339Date(from: startedAt) else {
            return "\("evolution.page.pipeline.startTimeLabel".localized): -"
        }
        return "\("evolution.page.pipeline.startTimeLabel".localized): \(Self.timeFormatter.string(from: date))"
    }

    private func durationText(_ entry: PipelineCycleTimelineEntry) -> String {
        if let durationSeconds = entry.durationSeconds, durationSeconds > 0 {
            return "\("evolution.page.pipeline.durationLabel".localized): \(EvolutionPipelineDateFormatting.formatDuration(durationSeconds))"
        }
        let normalized = entry.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "running" || normalized == "进行中" {
            if let date = EvolutionPipelineDateFormatting.rfc3339Date(from: entry.startedAt) {
                let elapsed = Date().timeIntervalSince(date)
                return "\("evolution.page.pipeline.durationLabel".localized): \(EvolutionPipelineDateFormatting.formatDuration(elapsed))"
            }
        }
        return "\("evolution.page.pipeline.durationLabel".localized): \("evolution.page.pipeline.durationUnknown".localized)"
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func localizedTerminalReason(_ code: String) -> String {
        let key = "evolution.terminalReason.\(code)"
        let localized = key.localized
        return localized == key ? code : localized
    }

    private func cycleStatusInfo(_ status: String) -> (color: Color, icon: String, label: String) {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "running":
            return (.green, "play.circle.fill", "evolution.status.running".localized)
        case "queued":
            return (.blue, "clock.fill", "evolution.status.queued".localized)
        case "completed", "done", "success":
            return (.green, "checkmark.circle.fill", "evolution.status.completed".localized)
        case "interrupted", "stopped":
            return (.orange, "pause.circle.fill", "evolution.status.interrupted".localized)
        case "failed_exhausted":
            return (.red, "xmark.circle.fill", "evolution.status.failedExhausted".localized)
        case "failed_system":
            return (.red, "exclamationmark.triangle.fill", "evolution.status.failedSystem".localized)
        case "idle":
            return (.secondary, "moon.fill", "evolution.status.idle".localized)
        default:
            return (.secondary, "questionmark.circle", status)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

#endif
