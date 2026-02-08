import SwiftUI

// MARK: - 新建文件对话框

struct NewFileDialogView: View {
    @Binding var fileName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    private var isValid: Bool {
        !fileName.isEmpty && !fileName.contains("/") && !fileName.contains("\\")
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .foregroundColor(.accentColor)
                Text("rightPanel.newFile.title".localized)
                    .font(.headline)
            }

            TextField("rightPanel.newFile.placeholder".localized, text: $fileName)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    if isValid {
                        onConfirm()
                    }
                }

            HStack(spacing: 12) {
                Button("common.cancel".localized) {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("common.confirm".localized) {
                    onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

// MARK: - 重命名对话框

struct RenameDialogView: View {
    let originalName: String
    @Binding var newName: String
    let isDir: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    private var isValid: Bool {
        !newName.isEmpty && newName != originalName && !newName.contains("/") && !newName.contains("\\")
    }

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Image(systemName: isDir ? "folder" : "doc")
                    .foregroundColor(.accentColor)
                Text(isDir ? "rightPanel.renameFolder".localized : "rightPanel.renameFile".localized)
                    .font(.headline)
            }

            // 输入框
            TextField("rightPanel.newName".localized, text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    if isValid {
                        onConfirm()
                    }
                }

            // 按钮
            HStack(spacing: 12) {
                Button("common.cancel".localized) {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("common.confirm".localized) {
                    onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            // 自动聚焦并选中文件名（不含扩展名）
            isTextFieldFocused = true
        }
    }
}

// MARK: - View 条件修饰符扩展

extension View {
    /// 条件应用修饰符
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
