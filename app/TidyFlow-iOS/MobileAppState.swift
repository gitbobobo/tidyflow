import Foundation
import SwiftUI
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
    // 连接表单
    @Published var host: String = ""
    @Published var port: String = "47999"
    @Published var pairCode: String = ""
    @Published var deviceName: String = UIDevice.current.name

    // 连接状态
    @Published var connecting: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectionMessage: String = ""
    @Published var errorMessage: String = ""

    // 数据
    @Published var projects: [ProjectInfo] = []
    @Published var workspaces: [WorkspaceInfo] = []

    // 导航
    @Published var navigationPath = NavigationPath()

    // 终端
    @Published var currentTermId: String = ""
    @Published var terminalCols: Int = 80
    @Published var terminalRows: Int = 24

    // 桥接
    let bridge = MobileBridge()
    private let wsClient = WSClient()

    init() {
        setupWSCallbacks()
    }

    // MARK: - 连接

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
        currentTermId = ""
        connectionMessage = "已断开"
    }

    // MARK: - 项目/工作空间

    func selectProject(_ projectName: String) {
        workspaces = []
        wsClient.requestListWorkspaces(project: projectName)
    }

    // MARK: - 终端

    func createTerminalForWorkspace(project: String, workspace: String) {
        wsClient.requestTermCreate(project: project, workspace: workspace)
    }

    /// 发送特殊键序列到终端
    func sendSpecialKey(_ sequence: String) {
        guard !currentTermId.isEmpty else { return }
        wsClient.sendTerminalInput(sequence, termId: currentTermId)
    }

    /// 离开终端视图时清理
    func detachTerminal() {
        currentTermId = ""
    }

    // MARK: - Bridge 回调

    func setupBridgeCallbacks() {
        bridge.onReady = { [weak self] cols, rows in
            guard let self else { return }
            self.terminalCols = cols
            self.terminalRows = rows
            // 终端就绪后，如果已有 termId，发送 resize
            if !self.currentTermId.isEmpty {
                self.wsClient.requestTermResize(termId: self.currentTermId, cols: cols, rows: rows)
            }
        }

        bridge.onTerminalData = { [weak self] data in
            guard let self, !self.currentTermId.isEmpty else { return }
            self.wsClient.sendTerminalInput(data, termId: self.currentTermId)
        }

        bridge.onTerminalResized = { [weak self] cols, rows in
            guard let self else { return }
            self.terminalCols = cols
            self.terminalRows = rows
            if !self.currentTermId.isEmpty {
                self.wsClient.requestTermResize(termId: self.currentTermId, cols: cols, rows: rows)
            }
        }

        bridge.onOpenURL = { urlString in
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - WS 回调

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
        }

        wsClient.onWorkspacesList = { [weak self] result in
            guard let self else { return }
            self.workspaces = result.items
        }

        wsClient.onTermCreated = { [weak self] result in
            guard let self else { return }
            self.currentTermId = result.termId
            self.wsClient.requestTermResize(
                termId: result.termId,
                cols: self.terminalCols,
                rows: self.terminalRows
            )
        }

        wsClient.onTermAttached = { [weak self] result in
            guard let self else { return }
            self.currentTermId = result.termId
            // 写入 scrollback 到 xterm.js
            if !result.scrollback.isEmpty {
                self.bridge.writeOutput(result.scrollback)
            }
            self.wsClient.requestTermResize(
                termId: result.termId,
                cols: self.terminalCols,
                rows: self.terminalRows
            )
        }

        wsClient.onTerminalOutput = { [weak self] termId, bytes in
            guard let self else { return }
            if let termId, self.currentTermId.isEmpty {
                self.currentTermId = termId
            }
            self.bridge.writeOutput(bytes)
        }

        wsClient.onTerminalExit = { [weak self] _, _ in
            // 终端退出，可选择通知用户
            _ = self
        }

        wsClient.onTermClosed = { [weak self] termId in
            guard let self else { return }
            if self.currentTermId == termId {
                self.currentTermId = ""
            }
        }

        wsClient.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    // MARK: - HTTP 配对

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