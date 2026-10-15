import AppKit
import ApplicationServices
import MacAdapters
import VimCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let keyboard = KeyboardInterceptor()
    private lazy var coordinator = SessionCoordinator(keyboard: keyboard)
    private let renderer = CursorRenderer()
    private let hud = ModeHUD()
    private var runtime = RuntimeStatus()
    private var status: NSStatusItem!
    private let messageItem = NSMenuItem(title: "正在启动", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let shortcutItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vimac/config")
    private var config = Configuration()
    private var fixture: Process?
    private var stateWindow: NSWindow?
    private let stateTitle = NSTextField(wrappingLabelWithString: "")
    private let stateDetail = NSTextField(wrappingLabelWithString: "")
    private let statePermissions = NSTextField(wrappingLabelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.autosaveName = "VimacStatus"
        status.isVisible = true
        let menu = NSMenu()
        menu.addItem(messageItem)
        menu.addItem(permissionItem)
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
        add(menu, "运行状态 / 权限设置…", #selector(showState))
        add(menu, "退出 Vim 模式", #selector(stopMode))
        add(menu, "重新检查权限并连接", #selector(startListening))
        add(menu, "打开辅助功能设置", #selector(openAccessibility))
        add(menu, "打开输入监控设置", #selector(openInputMonitoring))
        add(menu, "打开试验文本窗口", #selector(openFixture))
        add(menu, "重新加载配置", #selector(reloadConfig))
        add(menu, "生成 / 打开配置", #selector(openConfig))
        menu.addItem(.separator())
        add(menu, "退出 Vimac", #selector(quit))
        status.menu = menu
        coordinator.onUpdate = { [weak self] mode, rect, message, style in
            guard let self else { return }
            let oldMode = self.runtime.mode
            self.runtime.updateEditor(mode: mode, detail: message)
            self.updateDisplay()
            self.renderer.render(mode: mode, rect: rect, style: style)
            if self.runtime.listener == .ready && oldMode != mode && (oldMode == .off || mode == .off) {
                self.hud.show(title: self.runtime.headline, subtitle: mode == .off ? message : self.runtime.guidance)
            }
        }
        coordinator.onFailure = { [weak self] message in
            guard let self else { return }
            self.refreshService()
            if self.runtime.listener == .ready {
                self.hud.show(title: "未能接管当前输入框", subtitle: message, duration: 3.5)
            }
        }
        keyboard.onStarted = { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.setListener(.ready, detail: "监听已启动，等待快捷键", announce: true)
                } else if !CGPreflightListenEventAccess() {
                    self.setListener(.needsInputMonitoring, detail: "请开启输入监控权限", announce: true)
                    self.showState()
                } else {
                    self.setListener(.failed, detail: "键盘监听创建失败，请检查权限或重新启动", announce: true)
                    self.showState()
                }
            }
        }
        reloadConfig()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.coordinator.cancel("焦点或系统会话已变化")
                self?.renderer.hide()
            })
        }
        // 权限提示和自动恢复必须由实际 .app 进程执行，不能用终端子进程结果替代。
        refreshService()
        if runtime.listener == .needsAccessibility {
            showState()
            requestAccessibility()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshService()
        }
    }

    private func setListener(_ listener: ListenerStatus, detail: String, announce: Bool = false) {
        let changed = runtime.listener != listener
        runtime.listener = listener
        runtime.detail = detail
        updateDisplay()
        if changed && announce { hud.show(title: runtime.headline, subtitle: runtime.guidance, duration: 3) }
    }

    private func refreshService() {
        guard AXIsProcessTrusted() else {
            if keyboard.isListening { keyboard.stop(); coordinator.cancel("辅助功能权限已失效") }
            setListener(.needsAccessibility, detail: "等待辅助功能授权")
            renderer.hide()
            return
        }
        if keyboard.isListening {
            if runtime.listener != .ready { setListener(.ready, detail: "权限已生效，监听已连接", announce: true) }
            else { updateDisplay() }
            return
        }
        if keyboard.isStarting { return }
        // 未授权时不反复弹系统对话框；获准后自动重连。
        if runtime.listener == .needsInputMonitoring && !CGPreflightListenEventAccess() {
            updateDisplay()
            return
        }
        setListener(.starting, detail: "正在连接全局键盘监听")
        keyboard.start()
    }

    private func updateDisplay() {
        let color: NSColor = runtime.listener == .ready ? .systemGreen :
            (runtime.listener == .starting ? .systemBlue : .systemOrange)
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        title.append(NSAttributedString(string: runtime.menuTitle))
        status.button?.attributedTitle = title
        status.button?.toolTip = runtime.headline + "\n" + runtime.guidance + "\n" + runtime.detail
        status.button?.setAccessibilityLabel(runtime.menuTitle)
        messageItem.title = runtime.headline
        permissionItem.title = "辅助功能：" + (AXIsProcessTrusted() ? "已授权" : "未授权")
            + " · 监听：" + (keyboard.isListening ? "运行中" : "未连接")
        shortcutItem.title = "开关快捷键：" + config.toggleKey
        stateTitle.stringValue = runtime.headline
        stateDetail.stringValue = runtime.guidance + "\n\n" + runtime.detail
        statePermissions.stringValue = permissionItem.title
            + "\n输入监控检查：" + (CGPreflightListenEventAccess() ? "通过" : "未授权")
            + " · 发送事件检查：" + (CGPreflightPostEventAccess() ? "通过" : "未授权")
            + "\n运行位置：" + Bundle.main.bundleURL.path
            + "\n进程：" + String(ProcessInfo.processInfo.processIdentifier)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }
    @objc private func stopMode() { coordinator.cancel(); renderer.hide() }
    @objc private func startListening() {
        if !AXIsProcessTrusted() { requestAccessibility() }
        else if !CGPreflightListenEventAccess() && !keyboard.isListening { _ = CGRequestListenEventAccess() }
        refreshService()
        if runtime.listener != .ready { showState() }
    }
    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func showState() {
        if stateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 370),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Vimac · 运行状态"
            window.isReleasedWhenClosed = false
            let content = window.contentView!
            stateTitle.font = .systemFont(ofSize: 21, weight: .semibold)
            stateTitle.frame = NSRect(x: 24, y: 296, width: 532, height: 50)
            stateDetail.frame = NSRect(x: 24, y: 188, width: 532, height: 100)
            statePermissions.font = .systemFont(ofSize: 11)
            statePermissions.textColor = .secondaryLabelColor
            statePermissions.frame = NSRect(x: 24, y: 92, width: 532, height: 88)
            for view in [stateTitle, stateDetail, statePermissions] { content.addSubview(view) }
            let buttons: [(String, Selector)] = [
                ("辅助功能设置", #selector(openAccessibility)), ("输入监控设置", #selector(openInputMonitoring)),
                ("重新检查", #selector(startListening)), ("试验窗口", #selector(openFixture))]
            for (index, entry) in buttons.enumerated() {
                let button = NSButton(title: entry.0, target: self, action: entry.1)
                button.bezelStyle = .rounded
                button.frame = NSRect(x: 20 + index * 137, y: 24, width: 130, height: 34)
                content.addSubview(button)
            }
            window.center()
            stateWindow = window
        }
        updateDisplay()
        stateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showState()
        return false
    }

    @objc private func reloadConfig() {
        do {
            let next = FileManager.default.fileExists(atPath: configURL.path)
                ? try Configuration.decode(Data(contentsOf: configURL)) : Configuration()
            config = next
            runtime.shortcut = next.toggleKey
            coordinator.configure(next)
            switch next.theme.mode {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
            updateDisplay()
        } catch { showError("配置未生效，保留上次有效配置：\(error.localizedDescription)") }
    }
    @objc private func openConfig() {
        do {
            if !FileManager.default.fileExists(atPath: configURL.path) {
                try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try config.encoded().write(to: configURL, options: .withoutOverwriting)
            }
            NSWorkspace.shared.open(configURL)
        } catch { showError(error.localizedDescription) }
    }
    @objc private func openFixture() {
        coordinator.cancel()
        stateWindow?.orderOut(nil)
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VimacFixture")
        let development = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("VimacFixture")
        let executable = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : development
        do {
            let process = Process()
            process.executableURL = executable
            try process.run()
            fixture = process
        } catch { showError("试验窗口启动失败：\(error.localizedDescription)") }
    }
    private func showError(_ message: String) {
        hud.show(title: "Vimac · 操作未完成", subtitle: message, duration: 4)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        keyboard.stop()
        renderer.hide()
        hud.hide()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

if CommandLine.arguments.contains("--check-permissions") {
    print("当前命令进程：accessibility=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())；已运行应用请查看其菜单中的运行状态")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
