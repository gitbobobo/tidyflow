import SwiftUI

/// API key 连接表单视图
struct ConnectionView: View {
    @EnvironmentObject var appState: MobileAppState
    private let isUITestMode: Bool = {
        switch ProcessInfo.processInfo.environment["UI_TEST_MODE"]?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }()

    var body: some View {
        Form {
            // 快速连接（有保存的连接时显示）
            if appState.hasSavedConnection {
                Section("快速连接") {
                    Button {
                        Task { await appState.autoReconnect() }
                    } label: {
                        HStack {
                            Text("自动连接")
                            Spacer()
                            if appState.autoConnecting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.autoConnecting || appState.connecting)

                    Button("清除保存的连接", role: .destructive) {
                        appState.clearSavedConnection()
                    }
                    .disabled(appState.autoConnecting || appState.connecting)
                }
            }

            Section("连接信息") {
                HStack {
                    Text("地址")
                        .frame(width: 50, alignment: .leading)
                    TextField("如 192.168.1.100", text: $appState.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("tf.connection.host")
                }
                HStack {
                    Text("端口")
                        .frame(width: 50, alignment: .leading)
                    TextField("47999", text: $appState.port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("tf.connection.port")
                }
                Toggle("HTTPS", isOn: $appState.useHTTPS)
                    .accessibilityIdentifier("tf.connection.https")
                HStack {
                    Text("API key")
                        .frame(width: 50, alignment: .leading)
                    SecureField("tfk_...", text: $appState.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("tf.connection.apiKey")
                }
            }
            .accessibilityIdentifier("tf.connection.form")

            Section {
                Button {
                    Task {
                        await appState.connectWithAPIKey()
                    }
                } label: {
                    HStack {
                        Text("使用 API key 连接")
                        Spacer()
                        if appState.connecting {
                            ProgressView()
                        }
                    }
                }
                .disabled(appState.connecting)
                .accessibilityIdentifier("tf.connection.submit")
            }

            if !appState.errorMessage.isEmpty {
                Section {
                    Text(appState.errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .accessibilityIdentifier("tf.connection.errorMessage")
                }
            }

            if !appState.connectionMessage.isEmpty {
                Section {
                    Text(appState.connectionMessage)
                        .foregroundColor(appState.isConnected ? .green : .secondary)
                        .font(.caption)
                        .accessibilityIdentifier("tf.connection.connectionMessage")
                }
            }
        }
        .navigationTitle("TidyFlow")
        .accessibilityIdentifier("tf.connection.page")
        .task {
            if isUITestMode {
                return
            }
            // 启动时自动重连
            if appState.hasSavedConnection && !appState.isConnected {
                await appState.autoReconnect()
            }
        }
        .onChange(of: appState.isConnected) { _, connected in
            if connected && appState.navigationPath.count == 0 {
                appState.navigationPath.append(MobileRoute.projects)
            }
        }
    }
}
