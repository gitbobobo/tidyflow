import Foundation
import UIKit

private struct PairExchangeHTTPBody: Encodable {
    let pairCode: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case pairCode = "pair_code"
        case deviceName = "device_name"
    }
}

private struct PairExchangeHTTPResponse: Decodable {
    let tokenId: String
    let wsToken: String
    let deviceName: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case wsToken = "ws_token"
        case deviceName = "device_name"
        case expiresAt = "expires_at"
    }
}

private struct PairErrorHTTPResponse: Decodable {
    let error: String
    let message: String
}

@MainActor
final class MobileAppState: ObservableObject {
    @Published var host: String = ""
    @Published var port: String = "47999"
    @Published var pairCode: String = ""
    @Published var deviceName: String = UIDevice.current.name

    @Published var connecting: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectionMessage: String = ""
    @Published var errorMessage: String = ""

    @Published var projects: [ProjectInfo] = []
    @Published var workspaces: [WorkspaceInfo] = []
    @Published var selectedProject: String = ""
    @Published var selectedWorkspace: String = ""

    @Published var currentTermId: String = ""
    @Published var terminalInput: String = ""
    @Published var terminalOutput: String = ""

    private let wsClient = WSClient()

    init() {
        setupWSCallbacks()
    }

    func pairAndConnect() async {
        errorMessage = ""
        connectionMessage = ""
        connecting = true
        defer { connecting = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            errorMessage = "请填写电脑地址"
            return
        }
        guard let portValue = Int(port), portValue > 0, portValue <= 65535 else {
            errorMessage = "端口无效"
            return
        }
        guard trimmedCode.count == 6 else {
            errorMessage = "配对码必须是 6 位数字"
            return
        }

        do {
            let token = try await exchangePairCode(
                host: trimmedHost,
                port: portValue,
                pairCode: trimmedCode,
                deviceName: trimmedDeviceName.isEmpty ? "iOS Device" : trimmedDeviceName
            )

            wsClient.disconnect()
            wsClient.updateAuthToken(token.wsToken)
            wsClient.updateBaseURL(
                AppConfig.makeWsURL(host: trimmedHost, port: portValue, token: token.wsToken),
                reconnect: false
            )
            wsClient.connect()
            connectionMessage = "已配对，正在连接..."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        wsClient.disconnect()
        isConnected = false
        connectionMessage = "已断开"
    }

    func selectProject(_ projectName: String) {
        selectedProject = projectName
        selectedWorkspace = ""
        workspaces = []
        wsClient.requestListWorkspaces(project: projectName)
    }

    func selectWorkspace(_ workspaceName: String) {
        selectedWorkspace = workspaceName
    }

    func createTerminalForSelectedWorkspace() {
        guard !selectedProject.isEmpty, !selectedWorkspace.isEmpty else {
            return
        }
        wsClient.requestTermCreate(project: selectedProject, workspace: selectedWorkspace)
    }

    func sendTerminalLine() {
        guard !currentTermId.isEmpty else { return }
        let line = terminalInput.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        wsClient.sendTerminalInput(line + "\n", termId: currentTermId)
        terminalInput = ""
    }

    private func setupWSCallbacks() {
        wsClient.onConnectionStateChanged = { [weak self] connected in
            guard let self else { return }
            self.isConnected = connected
            if connected {
                self.connectionMessage = "连接成功"
                self.errorMessage = ""
                self.wsClient.requestListProjects()
            } else {
                self.connectionMessage = "连接断开"
            }
        }

        wsClient.onProjectsList = { [weak self] result in
            guard let self else { return }
            self.projects = result.items
            if self.selectedProject.isEmpty, let first = result.items.first {
                self.selectProject(first.name)
            }
        }

        wsClient.onWorkspacesList = { [weak self] result in
            guard let self else { return }
            if result.project != self.selectedProject { return }
            self.workspaces = result.items
            if self.selectedWorkspace.isEmpty, let first = result.items.first {
                self.selectedWorkspace = first.name
            }
        }

        wsClient.onTermCreated = { [weak self] result in
            guard let self else { return }
            self.currentTermId = result.termId
            self.appendTerminalText("[term] created \(result.termId) @ \(result.workspace)")
            self.wsClient.requestTermResize(termId: result.termId, cols: 100, rows: 30)
        }

        wsClient.onTermAttached = { [weak self] result in
            guard let self else { return }
            self.currentTermId = result.termId
            self.appendTerminalText("[term] attached \(result.termId)")
            self.appendTerminalBytes(result.scrollback)
            self.wsClient.requestTermResize(termId: result.termId, cols: 100, rows: 30)
        }

        wsClient.onTerminalOutput = { [weak self] termId, bytes in
            guard let self else { return }
            if let termId, self.currentTermId.isEmpty {
                self.currentTermId = termId
            }
            self.appendTerminalBytes(bytes)
        }

        wsClient.onTerminalExit = { [weak self] _, code in
            self?.appendTerminalText("\n[term] exited with code \(code)\n")
        }

        wsClient.onTermClosed = { [weak self] termId in
            guard let self else { return }
            self.appendTerminalText("\n[term] closed \(termId)\n")
            if self.currentTermId == termId {
                self.currentTermId = ""
            }
        }

        wsClient.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    private func appendTerminalBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let text = String(data: Data(bytes), encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        appendTerminalText(text)
    }

    private func appendTerminalText(_ text: String) {
        terminalOutput += text
        if terminalOutput.count > 400_000 {
            terminalOutput.removeFirst(terminalOutput.count - 300_000)
        }
    }

    private func exchangePairCode(
        host: String,
        port: Int,
        pairCode: String,
        deviceName: String
    ) async throws -> PairExchangeHTTPResponse {
        guard let url = URL(string: "http://\(host):\(port)/pair/exchange") else {
            throw NSError(domain: "TidyFlowiOS", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "配对服务地址无效"
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(
            PairExchangeHTTPBody(pairCode: pairCode, deviceName: deviceName)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "TidyFlowiOS", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "服务端响应异常"
            ])
        }

        if (200..<300).contains(httpResponse.statusCode) {
            return try JSONDecoder().decode(PairExchangeHTTPResponse.self, from: data)
        }

        if let serverError = try? JSONDecoder().decode(PairErrorHTTPResponse.self, from: data) {
            throw NSError(domain: "TidyFlowiOS", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(serverError.error): \(serverError.message)"
            ])
        }

        throw NSError(domain: "TidyFlowiOS", code: httpResponse.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "配对失败 (HTTP \(httpResponse.statusCode))"
        ])
    }
}
