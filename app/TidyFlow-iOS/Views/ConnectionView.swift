import SwiftUI

/// 配对连接表单视图
struct ConnectionView: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        Form {
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
        .onChange(of: appState.isConnected) { _, connected in
            if connected {
                appState.navigationPath.append(MobileRoute.projects)
            }
        }
    }
}
