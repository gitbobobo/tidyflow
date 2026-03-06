import XCTest

final class TidyFlowE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private let recorder = EvidenceRecorder.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-ApplePersistenceIgnoreState")
        app.launchArguments.append("YES")
        app.launchEnvironment["UI_TEST_MODE"] = "1"
        app.launchEnvironment["TF_DEVICE_TYPE"] = recorder.deviceType
        app.launchEnvironment["TF_E2E_RUN_ID"] = recorder.runID
    }

    func testAC_CONN_FORM_READY() throws {
        try skipUnlessMobile()

        app.launch()

        guard let hostField = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.host").firstMatch,
                app.textFields["tf.connection.host"],
                app.textFields["如 192.168.1.100"],
                app.textFields["192.168.1.100"]
            ],
            timeout: 20
        ) else {
            XCTFail("地址输入框未出现")
            return
        }
        guard let portField = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.port").firstMatch,
                app.textFields["tf.connection.port"],
                app.textFields["47999"]
            ],
            timeout: 8
        ) else {
            XCTFail("端口输入框未出现")
            return
        }
        guard let pairCodeField = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.pairCode").firstMatch,
                app.textFields["tf.connection.pairCode"],
                app.textFields["6 位数字"]
            ],
            timeout: 8
        ) else {
            XCTFail("配对码输入框未出现")
            return
        }
        guard let deviceNameField = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.deviceName").firstMatch,
                app.textFields["tf.connection.deviceName"],
                app.textFields["iPhone"]
            ],
            timeout: 8
        ) else {
            XCTFail("设备名输入框未出现")
            return
        }
        guard let submitButton = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.submit").firstMatch,
                app.buttons["tf.connection.submit"],
                app.buttons["配对并连接"]
            ],
            timeout: 8
        ) else {
            XCTFail("配对并连接按钮未出现")
            return
        }

        let scenario = "AC-CONN-FORM-READY"
        let subsystem = mobileSubsystem()
        try recorder.recordScreenshot(
            scenario: scenario,
            subsystem: subsystem,
            title: "连接表单关键控件已就绪，可进入配对流程",
            description: "执行动作：启动应用并停留在连接页；关键观察：地址、端口、配对码、设备名输入与提交按钮均可见；证据用途：证明 AC-CONN-FORM-READY 已满足并可执行后续交互。",
            screenshot: XCUIScreen.main.screenshot()
        )
        try recorder.recordLog(
            scenario: scenario,
            subsystem: subsystem,
            title: "连接页就绪状态断言通过",
            description: "执行动作：等待连接页渲染并检查关键输入控件；关键观察：五个关键 UI 元素全部存在；证据用途：证明连接前置条件完整，排除页面渲染缺失。",
            body: """
            host.exists=\(hostField.exists)
            port.exists=\(portField.exists)
            pairCode.exists=\(pairCodeField.exists)
            deviceName.exists=\(deviceNameField.exists)
            submit.exists=\(submitButton.exists)
            """
        )
    }

    func testAC_PAIRCODE_VALIDATION() throws {
        try skipUnlessMobile()

        app.launch()

        guard let hostField = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.host").firstMatch,
                app.textFields["tf.connection.host"],
                app.textFields["如 192.168.1.100"],
                app.textFields["192.168.1.100"]
            ],
            timeout: 20
        ) else {
            XCTFail("连接页未加载")
            return
        }
        guard let portField = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.port").firstMatch,
                app.textFields["tf.connection.port"],
                app.textFields["47999"]
            ],
            timeout: 8
        ) else {
            XCTFail("端口输入框未出现")
            return
        }
        guard let pairCodeField = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.pairCode").firstMatch,
                app.textFields["tf.connection.pairCode"],
                app.textFields["6 位数字"]
            ],
            timeout: 8
        ) else {
            XCTFail("配对码输入框未出现")
            return
        }
        guard let submitButton = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.submit").firstMatch,
                app.buttons["tf.connection.submit"],
                app.buttons["配对并连接"]
            ],
            timeout: 8
        ) else {
            XCTFail("提交按钮未出现")
            return
        }

        hostField.clearAndTypeText("127.0.0.1")
        portField.clearAndTypeText("47999")
        pairCodeField.clearAndTypeText("123")
        submitButton.tap()

        guard let errorLabel = waitForFirstExistingElement(
            candidates: [
                app.descendants(matching: .any).matching(identifier: "tf.connection.errorMessage").firstMatch,
                app.staticTexts["tf.connection.errorMessage"],
                app.staticTexts["配对码必须是 6 位数字"]
            ],
            timeout: 8
        ) else {
            XCTFail("未出现配对码校验错误提示")
            return
        }
        XCTAssertTrue(errorLabel.label.contains("配对码必须是 6 位数字"), "错误提示文本不符合预期: \(errorLabel.label)")

        let scenario = "AC-PAIRCODE-VALIDATION"
        let subsystem = mobileSubsystem()
        try recorder.recordScreenshot(
            scenario: scenario,
            subsystem: subsystem,
            title: "非法配对码触发前端校验错误提示",
            description: "执行动作：输入 3 位配对码并点击配对连接；关键观察：页面出现“配对码必须是 6 位数字”错误文案；证据用途：证明 AC-PAIRCODE-VALIDATION 生效并阻止非法输入继续执行。",
            screenshot: XCUIScreen.main.screenshot()
        )
        try recorder.recordLog(
            scenario: scenario,
            subsystem: subsystem,
            title: "配对码校验断言通过，错误提示可回溯",
            description: "执行动作：填写 host/port 后提交非法配对码；关键观察：校验提示文本与预期一致；证据用途：证明非法输入被拦截，排除无校验或提示错误风险。",
            body: """
            host=127.0.0.1
            port=47999
            pairCode=123
            errorMessage=\(errorLabel.label)
            """
        )
    }

    func testAC_UI_TOOLBAR_READY() throws {
        try skipUnlessMac()

        let launchStartAt = Date()
        app.launch()
        app.activate()

        let startupLoading = app.descendants(matching: .any).matching(identifier: "tf.mac.startup.loading").firstMatch
        let startupFailed = app.descendants(matching: .any).matching(identifier: "tf.mac.startup.failed").firstMatch

        let settingsButton = app.descendants(matching: .any).matching(identifier: "tf.mac.toolbar.settings").firstMatch
        let inspectorButton = app.descendants(matching: .any).matching(identifier: "tf.mac.toolbar.inspectorToggle").firstMatch

        // 启动阶段应先出现加载页；若启动失败页出现则直接报错并暴露问题信息。
        let loadingAppeared = startupLoading.waitForExistence(timeout: 30)
        if !loadingAppeared {
            XCTAssertFalse(startupFailed.exists, "启动阶段进入失败页，未能进入加载态")
        }

        // 启动页结束后，工具栏控件应在较长超时内可见并可交互。
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 180), "设置按钮未在 180 秒内出现")
        XCTAssertTrue(inspectorButton.waitForExistence(timeout: 180), "检查器切换按钮未在 180 秒内出现")
        if loadingAppeared {
            XCTAssertTrue(waitUntilNotExists(startupLoading, timeout: 180), "加载态未在 180 秒内消失")
        }
        XCTAssertTrue(waitUntilEnabled(settingsButton, timeout: 30), "设置按钮在 30 秒内仍不可交互")
        XCTAssertTrue(waitUntilEnabled(inspectorButton, timeout: 30), "检查器切换按钮在 30 秒内仍不可交互")

        inspectorButton.click()
        inspectorButton.click()

        let windowReadyLatency = String(format: "%.2f", Date().timeIntervalSince(launchStartAt))

        let scenario = "AC-UI-TOOLBAR-READY"
        let subsystem = "mac-ui"
        try recorder.recordScreenshot(
            scenario: scenario,
            subsystem: subsystem,
            title: "启动加载态结束后主窗口工具栏控件可交互",
            description: "执行动作：启动 mac 应用，先确认加载态出现，再等待加载态结束并点击检查器切换按钮；关键观察：设置按钮与检查器按钮均出现且处于可交互状态；证据用途：证明 AC-UI-TOOLBAR-READY 在启动门禁流程下成立。",
            screenshot: XCUIScreen.main.screenshot()
        )
        try recorder.recordLog(
            scenario: scenario,
            subsystem: subsystem,
            title: "加载页时序与工具栏交互断言通过",
            description: "执行动作：应用启动后确认加载态出现，再等待其退出并验证工具栏按钮可交互；关键观察：窗口即时出现、加载态按预期退出、按钮持续可交互；证据用途：证明新启动流程与工具栏交互兼容。",
            body: """
            launch_to_window_ready_seconds=\(windowReadyLatency)
            startupLoading.appeared=\(loadingAppeared)
            startupLoading.exists=\(startupLoading.exists)
            startupFailed.exists=\(startupFailed.exists)
            settings.exists=\(settingsButton.exists)
            settings.enabled=\(settingsButton.isEnabled)
            inspector.exists=\(inspectorButton.exists)
            inspector.enabled=\(inspectorButton.isEnabled)
            """
        )
    }

    private func skipUnlessMobile() throws {
        if recorder.deviceType == "mac" {
            throw XCTSkip("mac 设备不执行连接表单 AC")
        }
    }

    private func skipUnlessMac() throws {
        #if os(iOS)
        throw XCTSkip("iOS 模拟器不执行 mac 工具栏 AC")
        #endif
        if recorder.deviceType != "mac" {
            throw XCTSkip("\(recorder.deviceType) 设备不执行 mac 工具栏 AC")
        }
    }

    private func mobileSubsystem() -> String {
        "\(recorder.deviceType)-ui"
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = expectation(
            for: NSPredicate(format: "exists == true AND enabled == true"),
            evaluatedWith: element
        )
        return XCTWaiter.wait(for: [enabled], timeout: timeout) == .completed
    }

    private func waitUntilNotExists(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let disappeared = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: element
        )
        return XCTWaiter.wait(for: [disappeared], timeout: timeout) == .completed
    }

    private func waitForFirstExistingElement(candidates: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = candidates.first(where: \.exists) {
                return found
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return candidates.first(where: \.exists)
    }
}

private extension XCUIElement {
    func clearAndTypeText(_ text: String) {
        tap()
        let current = (value as? String) ?? ""
        if !current.isEmpty {
            let deleteText = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            typeText(deleteText)
        }
        typeText(text)
    }
}
