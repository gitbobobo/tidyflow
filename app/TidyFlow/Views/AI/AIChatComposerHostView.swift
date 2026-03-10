import SwiftUI

struct AIChatComposerHostView<ComposerContent: View>: View {
    let pendingInteraction: AIChatPendingInteraction?
    let queuedPendingInteractionCount: Int
    let onQuestionReply: (AIQuestionRequestInfo, [[String]]) -> Void
    let onQuestionReject: (AIQuestionRequestInfo) -> Void
    @ViewBuilder let composerContent: () -> ComposerContent

    var body: some View {
        Group {
            if let pendingInteraction {
                pendingInteractionView(pendingInteraction)
            } else {
                composerContent()
            }
        }
    }

    @ViewBuilder
    private func pendingInteractionView(_ interaction: AIChatPendingInteraction) -> some View {
        let request = interaction.request
        let items = request.questions.map { question in
            ToolQuestionPromptItem(
                question: question.question,
                header: question.header,
                options: question.options.map { option in
                    ToolQuestionPromptOption(
                        optionID: option.optionID,
                        label: option.label,
                        description: option.description
                    )
                },
                multiple: question.multiple,
                custom: question.custom
            )
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.rectangle.badge.questionmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(interaction.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let detail = interaction.detail,
                       !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 12)

                if queuedPendingInteractionCount > 0 {
                    Text("还有 \(queuedPendingInteractionCount) 项待处理")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
            }

            ToolQuestionPromptView(
                items: items,
                interactive: true,
                answeredSelections: nil,
                onReply: { answers in
                    onQuestionReply(request, answers)
                },
                onReject: {
                    onQuestionReject(request)
                },
                onReplyAsMessage: nil
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AIChatPendingInteractionContainerStyle())
        .accessibilityIdentifier("tf.ai.pending-interaction")
    }
}

private struct AIChatPendingInteractionContainerStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        #else
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
        #endif
    }
}
