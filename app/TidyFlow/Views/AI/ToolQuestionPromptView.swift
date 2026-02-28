import SwiftUI

struct ToolQuestionPromptOption: Identifiable {
    var id: String { optionID ?? "\(label)|\(description)" }
    let optionID: String?
    let label: String
    let description: String
}

struct ToolQuestionPromptItem: Identifiable {
    var id: String { "\(header)|\(question)" }
    let question: String
    let header: String
    let options: [ToolQuestionPromptOption]
    let multiple: Bool
    let custom: Bool
}

struct ToolQuestionPromptView: View {
    let items: [ToolQuestionPromptItem]
    let interactive: Bool
    /// 已回答时从 metadata 传入的用户选择，用于只读渲染
    let answeredSelections: [[String]]?
    let onReply: (([[String]]) -> Void)?
    let onReject: (() -> Void)?
    let onReplyAsMessage: ((String) -> Void)?

    @State private var tab: Int = 0
    @State private var answers: [Int: [String]] = [:]
    @State private var customInputs: [Int: String] = [:]
    @State private var editingCustom: Bool = false
    @State private var didPopulateAnswers: Bool = false

    private var isSingleAutoSubmit: Bool {
        interactive && items.count == 1 && !(items.first?.multiple ?? false)
    }

    private var currentItem: ToolQuestionPromptItem? {
        guard tab >= 0, tab < items.count else { return nil }
        return items[tab]
    }

    private var canReply: Bool {
        onReply != nil
    }

    private var canReplyAsMessage: Bool {
        onReplyAsMessage != nil
    }

    private var canSubmit: Bool {
        canReply || canReplyAsMessage
    }

    private var isConfirmStep: Bool {
        !isSingleAutoSubmit && tab == items.count
    }

    private var currentAnswers: [String] {
        answers[tab] ?? []
    }

    private var customInput: String {
        customInputs[tab] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 多问题 tab 栏：交互态和只读态都可切换查看
            if items.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            Button(item.header) {
                                tab = index
                                editingCustom = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(tab == index ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((tab == index ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                            .cornerRadius(6)
                        }

                        // 确认 tab 仅在交互态显示
                        if interactive {
                            Button("确认") {
                                tab = items.count
                                editingCustom = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isConfirmStep ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((isConfirmStep ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                            .cornerRadius(6)
                        }
                    }
                }
            }

            if isConfirmStep && interactive {
                VStack(alignment: .leading, spacing: 6) {
                    Text("请确认你的选择")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.question)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                            Text((answers[index] ?? []).isEmpty ? "未回答" : (answers[index] ?? []).joined(separator: "、"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(8)
                    }
                }
            } else if let item = currentItem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.question + (interactive && item.multiple ? "（可多选）" : ""))
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(item.options) { option in
                        let picked = currentAnswers.contains(option.label)
                        Button {
                            handleOptionTap(option: option.label, multiple: item.multiple)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                if picked {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(picked ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(!interactive)
                    }

                    // 只读态：显示不在选项列表中的自定义答案
                    if !interactive {
                        let optionLabels = Set(item.options.map(\.label))
                        let customAnswers = currentAnswers.filter { !optionLabels.contains($0) }
                        if !customAnswers.isEmpty {
                            ForEach(customAnswers, id: \.self) { answer in
                                HStack(spacing: 6) {
                                    Text(answer)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.accentColor)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(8)
                            }
                        }
                    }

                    // 交互态：自定义输入
                    if interactive && item.custom {
                        Button {
                            editingCustom = true
                        } label: {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("自定义答案")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                    if !editingCustom && !customInput.isEmpty {
                                        Text(customInput)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                Spacer(minLength: 0)
                                if currentAnswers.contains(customInput), !customInput.isEmpty {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    if interactive && editingCustom {
                        HStack(spacing: 6) {
                            TextField("输入自定义答案", text: Binding(
                                get: { customInputs[tab] ?? "" },
                                set: { customInputs[tab] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            Button(item.multiple ? "添加" : "提交") {
                                submitCustom(multiple: item.multiple)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                            Button("取消") {
                                editingCustom = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if interactive {
                HStack(spacing: 10) {
                    if let onReject {
                        Button("忽略") {
                            onReject()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }

                    if !isSingleAutoSubmit {
                        if isConfirmStep {
                            if canSubmit {
                                Button("提交") {
                                    submitAll()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.accentColor)
                            } else {
                                Text("历史记录不可提交")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        } else if currentItem?.multiple == true {
                            Button("下一步") {
                                tab = min(items.count, tab + 1)
                                editingCustom = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor((currentAnswers.isEmpty) ? .secondary : .accentColor)
                            .disabled(currentAnswers.isEmpty)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .onAppear {
            populateAnsweredSelections()
        }
    }

    /// 只读态：从 metadata 预填充用户已选答案
    private func populateAnsweredSelections() {
        guard !interactive, !didPopulateAnswers,
              let selections = answeredSelections else { return }
        didPopulateAnswers = true
        for (index, group) in selections.enumerated() where index < items.count {
            answers[index] = group
        }
    }

    private func handleOptionTap(option: String, multiple: Bool) {
        guard interactive else { return }
        if multiple {
            var next = answers[tab] ?? []
            if let idx = next.firstIndex(of: option) {
                next.remove(at: idx)
            } else {
                next.append(option)
            }
            answers[tab] = next
            return
        }
        answers[tab] = [option]
        if isSingleAutoSubmit {
            submitPayload([[option]])
            return
        }
        tab = min(items.count, tab + 1)
        editingCustom = false
    }

    private func submitCustom(multiple: Bool) {
        guard interactive else { return }
        let value = (customInputs[tab] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            editingCustom = false
            return
        }
        if multiple {
            var next = answers[tab] ?? []
            if !next.contains(value) {
                next.append(value)
            }
            answers[tab] = next
            editingCustom = false
            return
        }
        answers[tab] = [value]
        if isSingleAutoSubmit {
            submitPayload([[value]])
            return
        }
        tab = min(items.count, tab + 1)
        editingCustom = false
    }

    private func submitAll() {
        guard interactive else { return }
        let payload: [[String]] = items.enumerated().map { answers[$0.offset] ?? [] }
        submitPayload(payload)
    }

    private func submitPayload(_ payload: [[String]]) {
        if let onReply {
            onReply(payload)
            return
        }
        guard let onReplyAsMessage else { return }
        onReplyAsMessage(buildReplyMessage(payload: payload))
    }

    private func buildReplyMessage(payload: [[String]]) -> String {
        var lines: [String] = ["以下是我对该问题卡片的回答："]
        for (idx, item) in items.enumerated() {
            let header = item.header.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = header.isEmpty ? "问题\(idx + 1)" : header
            let answers = payload[safe: idx]?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            let answerText = answers.isEmpty ? "未回答" : answers.joined(separator: "、")
            lines.append("\(idx + 1). \(title)：\(item.question)")
            lines.append("答案：\(answerText)")
        }
        return lines.joined(separator: "\n")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
