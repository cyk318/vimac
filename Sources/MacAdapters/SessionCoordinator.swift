import AppKit
import VimCore

/// 引擎、文本快照和寄存器仅由此串行队列持有。会话失效后不回放旧按键。
public final class SessionCoordinator {
    private let queue = DispatchQueue(label: "Vimac editing", qos: .userInteractive)
    private let gate = NSLock()
    private var generation = 0
    private var pending = 0
    private var sessionGeneration = 0
    private var insertTransition = false
    private var inputVersion = 0
    private var geometryScheduled = false
    private let provider = AccessibilityProvider()
    private let clipboard = ClipboardBridge()
    private let focusMonitor = FocusMonitor()
    private let keyboard: KeyboardInterceptor
    private var engine = VimEngine()
    private var webSession: WebNavigationSession?
    private var mode: Mode { webSession?.mode ?? engine.mode }
    private var parser = KeyParser()
    private var history = ChangeHistory()
    private var config = Configuration()
    private var target: FocusTarget?
    private var lastSnapshot: Snapshot?
    private var timer: DispatchSourceTimer?
    public var onUpdate: ((Mode, CGRect?, String, CursorStyle, Bool) -> Void)?
    public var onFailure: ((String) -> Void)?

    public init(keyboard: KeyboardInterceptor) {
        self.keyboard = keyboard
        // 宿主可能重复发送焦点通知，必须核对元素身份后再结束会话。
        focusMonitor.onChange = { [weak self] in self?.queue.async { self?.refresh() } }
        provider.canProceed = { [weak self] in
            guard let self else { return false }
            self.gate.lock(); defer { self.gate.unlock() }
            return self.sessionGeneration == self.generation
        }
        keyboard.onKey = { [weak self] key in self?.submit { self?.handle(key) } }
        keyboard.onToggle = { [weak self] in self?.submit { self?.toggle() } }
        keyboard.onCancel = { [weak self] message in self?.cancel(message) }
        keyboard.onNativeShortcut = { [weak self] in self?.cancel("系统快捷键：已退出 Vim 模式") }
        keyboard.onScroll = { [weak self] in self?.scheduleGeometryRefresh() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }
    deinit { timer?.cancel() }

    public func configure(_ config: Configuration) {
        cancel("配置已加载，Vim 模式已关闭")
        queue.async { self.config = config; self.publish("已关闭") }
    }
    public func cancel(_ message: String = "已关闭") {
        gate.lock(); generation += 1; gate.unlock()
        // 立即放行新输入；旧队列仍会检查代数，并取消未发送的编辑动作。
        keyboard.disableRouting()
        queue.async { self.stop(message) }
    }
    private func submit(_ action: @escaping () -> Void) {
        gate.lock()
        if pending >= 64 { gate.unlock(); cancel("命令队列已满，已退出接管"); return }
        pending += 1
        let token = generation
        gate.unlock()
        queue.async {
            self.gate.lock()
            let valid = token == self.generation
            self.pending -= 1
            self.gate.unlock()
            if valid { action() }
        }
    }
    private func stop(_ message: String, notify: Bool = false) {
        if mode != .off || notify {
            provider.trace("session.stop", ["mode": mode.rawValue, "reason": message, "failure": String(notify)])
        }
        gate.lock(); generation += 1; gate.unlock()
        engine.stop(); webSession = nil; parser.reset(); target = nil; lastSnapshot = nil
        history.cancelPending()
        insertTransition = false
        focusMonitor.stop()
        publish(message)
        if notify { DispatchQueue.main.async { [weak self] in self?.onFailure?(message) } }
    }
    private func toggle() {
        if mode != .off { stop("已关闭"); return }
        do {
            gate.lock(); sessionGeneration = generation; gate.unlock()
            provider.diagnosticContext = ["session": UUID().uuidString, "operation": "begin"]
            let focus = try provider.focus()
            // 首次正文读取也可能失败，必须先记录目标以便关联接管失败。
            provider.diagnosticContext["pid"] = String(focus.pid)
            provider.trace("session.probe", ["application": NSRunningApplication(processIdentifier: focus.pid)?.bundleIdentifier ?? "unknown"])
            provider.traceCapabilities(focus)
            if provider.isWebEditor(focus) {
                // 网页接管不经过 snapshot / VimEngine，避免单一正文能力阻断整个会话。
                provider.diagnosticContext["adapter"] = "native_navigation"
                let session = WebNavigationSession(provider: provider, target: focus, clipboard: clipboard)
                try session.begin()
                target = focus
                webSession = session
                focusMonitor.start(pid: focus.pid)
                publish(session.message)
                return
            }
            provider.diagnosticContext["adapter"] = "exact_text"
            try provider.requireWritableSelection(focus)
            let snapshot = try provider.snapshot(focus)
            target = focus
            provider.diagnosticContext["pid"] = String(focus.pid)
            provider.trace("session.begin", ["application": NSRunningApplication(processIdentifier: focus.pid)?.bundleIdentifier ?? "unknown",
                                             "web_editor": String(provider.isWebEditor(focus)),
                                             "selection": NSStringFromRange(snapshot.selection),
                                             "utf16_count": String(snapshot.text.utf16.count)])
            if case .select(let range) = engine.begin(snapshot) { try provider.select(range, target: focus) }
            lastSnapshot = try provider.snapshot(focus)
            focusMonitor.start(pid: focus.pid)
            publish("NORMAL · 当前控件支持精确选区")
        } catch { stop(error.localizedDescription, notify: true) }
    }
    private func handle(_ input: KeyInput) {
        guard let target, mode != .off else { return }
        do {
            inputVersion += 1
            provider.diagnosticContext["operation"] = String(inputVersion)
            provider.diagnosticContext.removeValue(forKey: "command")
            provider.trace("input.handle", ["mode": mode.rawValue,
                                             "key": parser.collectingText || mode == .insert && input.key != "Esc" ? "<text>" : input.key,
                                             "repeated": String(input.repeated),
                                             "queue_delay_ms": String(Int((ProcessInfo.processInfo.systemUptime - input.time) * 1000))])
            if mode == .insert && input.key != "Esc" {
                try provider.replay(input.event, target: target)
                finishInsertTransitionWhenIdle()
                publish("INSERT")
                return
            }
            if mode == .insert && input.key == "Esc" {
                insertTransition = false
            }
            if let webSession {
                let request = mode == .insert ? (input.key == "Esc" ? ParsedCommand(.normal) : nil)
                    : parser.parse(input.key, time: input.time, repeated: input.repeated, mappings: config.mappings(for: mode))
                guard let request else { publish(parser.message); return }
                provider.diagnosticContext["command"] = request.command.rawValue
                provider.trace("command.begin", ["mode": mode.rawValue])
                try webSession.execute(request, queuedFor: ProcessInfo.processInfo.systemUptime - input.time)
                if mode == .insert {
                    insertTransition = true
                    finishInsertTransitionWhenIdle()
                }
                publish(webSession.message)
                return
            }
            let snapshot = try provider.snapshot(target)
            provider.trace("command.snapshot", ["selection": NSStringFromRange(snapshot.selection),
                                                "utf16_count": String(snapshot.text.utf16.count),
                                                "text_changed": String(lastSnapshot.map { $0.text != snapshot.text } ?? false)])
            if SnapshotSynchronization.mustEndSession(mode: mode, previous: lastSnapshot, current: snapshot) {
                throw ProviderError.unavailable("文本或选区由外部改变，已退出接管")
            }
            if mode == .normal, snapshot != lastSnapshot {
                parser.reset()
                engine.synchronize(snapshot)
            }
            let request: ParsedCommand?
            if mode == .insert { request = input.key == "Esc" ? ParsedCommand(.normal) : nil }
            else { request = parser.parse(input.key, time: input.time, repeated: input.repeated, mappings: config.mappings(for: mode)) }
            guard let request else { publish(parser.message); return }
            provider.diagnosticContext["command"] = request.command.rawValue
            let previousMode = mode
            provider.trace("command.begin", ["mode": previousMode.rawValue])
            let intent: EditIntent
            if request.command == .repeatChange {
                guard let repeated = history.replay(engine: &engine, snapshot: snapshot, register: clipboard.current()) else {
                    publish("没有可重复的已确认修改"); return
                }
                intent = repeated
            } else { intent = engine.execute(request, snapshot: snapshot, register: clipboard.current()) }
            try apply(intent, snapshot: snapshot, target: target)
            if mode == .insert {
                insertTransition = true
                finishInsertTransitionWhenIdle()
            }
            lastSnapshot = try provider.snapshot(target)
            if let lastSnapshot { history.confirm(request, intent: intent, before: snapshot, after: lastSnapshot, mode: mode, linewise: engine.linewiseVisual) }
            if let lastSnapshot { engine.synchronize(lastSnapshot) }
            provider.trace("command.complete", ["from_mode": previousMode.rawValue, "mode": mode.rawValue,
                                                 "selection": lastSnapshot.map { NSStringFromRange($0.selection) } ?? "unknown"])
            publish(mode.rawValue.uppercased())
        } catch { stop(error.localizedDescription, notify: true) }
    }

    private func apply(_ intent: EditIntent, snapshot: Snapshot, target: FocusTarget) throws {
        try provider.ensure(snapshot, target: target)
        switch intent {
        case .none: break
        case .select(let range): try provider.select(range, target: target)
        case .copy(let register, let caret):
            try clipboard.copy(register)
            try provider.select(NSRange(location: caret, length: 0), target: target)
        case .undo, .redo:
            try provider.post(key: 6, flags: intent == .redo ? [.maskCommand, .maskShift] : .maskCommand, target: target)
            _ = try provider.awaitText(nil, previous: snapshot, target: target)
        case .replace(let range, let text, let caret, let register):
            let expected = (snapshot.text as NSString).replacingCharacters(in: range, with: text)
            try provider.select(range, target: target)
            let selected = Snapshot(text: snapshot.text, selection: range, wordBreakOffsets: snapshot.wordBreakOffsets)
            try provider.ensure(selected, target: target)
            if text.isEmpty {
                if range.length > 0 { try provider.post(key: 51, target: target) }
            } else {
                let saved = try clipboard.preparePaste(text)
                try clipboard.verify(saved)
                try provider.ensure(selected, target: target)
                try provider.post(key: 9, flags: .maskCommand, target: target)
                _ = try provider.awaitText(expected, previous: snapshot, target: target)
                clipboard.restore(saved)
            }
            _ = try provider.awaitText(expected, previous: snapshot, target: target)
            if let register { try clipboard.copy(register) }
            let buffer = TextBuffer(expected)
            let position = mode == .insert ? min(caret, expected.utf16.count)
                : buffer.offsets[buffer.normalPosition(buffer.index(atUTF16: caret))]
            try provider.select(NSRange(location: position, length: 0), target: target)
        }
    }
    private func refresh() {
        guard let target, mode != .off else { return }
        do {
            if let webSession {
                try webSession.refresh()
                publish(webSession.message)
                return
            }
            let current = try provider.snapshot(target)
            if current != lastSnapshot {
                provider.trace("host.changed", ["mode": mode.rawValue,
                                                "selection": NSStringFromRange(current.selection),
                                                "utf16_count": String(current.text.utf16.count),
                                                "text_changed": String(lastSnapshot.map { $0.text != current.text } ?? false)])
            }
            if SnapshotSynchronization.mustEndSession(mode: mode, previous: lastSnapshot, current: current) {
                stop("文本或选区已改变，已退出接管"); return
            }
            if mode == .normal, current != lastSnapshot {
                parser.reset()
                engine.synchronize(current)
            }
            lastSnapshot = current
            publish(mode.rawValue.uppercased())
        } catch { stop(error.localizedDescription, notify: true) }
    }
    private func scheduleGeometryRefresh() {
        queue.async { [weak self] in
            guard let self, self.mode != .off, !self.geometryScheduled else { return }
            self.geometryScheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self else { return }
                self.geometryScheduled = false
                guard let target = self.target else { return }
                do {
                    try self.provider.verify(target)
                    self.publish(self.mode.rawValue.uppercased())
                } catch { self.stop(error.localizedDescription, notify: true) }
            }
        }
    }
    private func finishInsertTransitionWhenIdle() {
        let version = inputVersion
        let session = sessionGeneration
        // 一小段无输入间隙后才放行，防止新原生按键越过队列中正在重放的按键。
        queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.mode == .insert, self.sessionGeneration == session,
                  self.inputVersion == version else { return }
            self.gate.lock(); let empty = self.pending == 0; self.gate.unlock()
            guard empty else { self.finishInsertTransitionWhenIdle(); return }
            self.insertTransition = false
            self.publish("INSERT")
        }
    }
    private func publish(_ message: String) {
        gate.lock()
        let cancelled = mode != .off && sessionGeneration != generation
        gate.unlock()
        if cancelled { keyboard.disableRouting(); return }
        gate.lock()
        let hasQueuedKeys = pending > 0
        gate.unlock()
        // 清空过渡期输入之前继续拦截入队，避免新输入越过尚未重放的旧输入。
        keyboard.update(mode: mode, shortcut: try! Shortcut(config.toggleKey),
                        bufferInsert: mode == .insert && (insertTransition || hasQueuedKeys))
        // 网页没有可靠字符范围时不猜测块光标，保留宿主原生插入光标。
        let rect = target.flatMap { target in lastSnapshot.flatMap { snapshot in
            mode == .insert ? nil : provider.bounds(engine.cursorRange(in: snapshot.text), target: target)
        } }
        let currentMode = mode
        let displayMessage = parser.message.isEmpty ? (webSession?.message ?? message) : parser.message
        let limitedNavigation = webSession != nil
        let style = config.cursor
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(currentMode, rect, displayMessage, style, limitedNavigation) }
    }
}
