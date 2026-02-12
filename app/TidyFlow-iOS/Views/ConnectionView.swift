import SwiftUI

/// 配对连接表单视图
struct ConnectionView: View {
    @EnvironmentObject var appState: MobileAppState

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
                }
                HStack {
                    Text("端口")
                        .frame(width: 50, alignment: .leading)
                    TextField("47999", text: $appState.port)
                        .keyboardType(.numberPad)
                }
                Toggle("HTTPS", isOn: $appState.useHTTPS)
                HStack {
                    Text("配对码")
                        .frame(width: 50, alignment: .leading)
                    TextField("6 位数字", text: $appState.pairCode)
                        .keyboardType(.numberPad)
                }
                HStack {
                    Text("设备名")
                        .frame(width: 50, alignment: .leading)
                    TextField("iPhone", text: $appState.deviceName)
                }
            }

            Section {
                Button {
                    Task {
                        await appState.pairAndConnect()
                    }
                } label: {
                    HStack {
                        Text("配对并连接")
                        Spacer()
                        if appState.connecting {
                            ProgressView()
                        }
                    }
                }
                .disabled(appState.connecting)
            }

            if !appState.errorMessage.isEmpty {
                Section {
                    Text(appState.errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            if !appState.connectionMessage.isEmpty {
                Section {
                    Text(appState.connectionMessage)
                        .foregroundColor(appState.isConnected ? .green : .secondary)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("TidyFlow")
        .task {
            // 启动时自动重连
            if appState.hasSavedConnection && !appState.isConnected {
                await appState.autoReconnect()
            }
        }
        .onChange(of: appState.isConnected) { _, connected in
            if connected {
                appState.navigationPath.append(MobileRoute.projects)
            }
        }
    }
}
