import AppKit
import VimCore

/// 精确编辑仅对当前32K以内的控件/简单块启用，AX仅用于焦点和宿主按键。
/// 范围计算复用原生引擎；正文不会写入日志或持久化。
final class ChromeEditingSession: WebEditingSession {
    private let provider: AccessibilityProvider
    private let target: FocusTarget
    private let clipboard: ClipboardBridge
    private let token = UUID().uuidString
    private var engine = VimEngine()
    private var history = ChangeHistory()
    private var previous: State?
    private var needsRebind = false
    var mode: Mode { engine.mode }
    private(set) var message = "Chrome 精确编辑 · 当前控件/简单块"

    struct State: Decodable {
        var status: String
        var text: String?
        var anchor: Int?
        var focus: Int?
        var control: Bool?
        var multiline: Bool?
        var block: Bool?
        var lineEditing: Bool?
        var snapshot: Snapshot {
            Snapshot(text: text!, selection: NSRange(location: min(anchor!, focus!), length: abs(anchor! - focus!)))
        }
    }

    init(provider: AccessibilityProvider, target: FocusTarget, clipboard: ClipboardBridge) {
        self.provider = provider; self.target = target; self.clipboard = clipboard
    }
    func begin() throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
            throw WordNavigationError.unavailable("扩展编辑当前仅支持 Chrome")
        }
        let state: State
        do { state = try evaluate(["action": "begin"]) }
        catch { throw WordNavigationError.unavailable("无法读取Chrome编辑控件，请检查自动化与JavaScript权限") }
        guard state.status == "ok" else { throw WordNavigationError.unavailable("当前控件无法精确编辑：\(state.status)") }
        try validate(state)
        _ = engine.begin(state.snapshot)
        previous = state
    }
    func refresh() throws {
        try provider.verify(target)
        // 不每100ms跨进程读取正文；每条命令前核实，Insert 保持宿主输入。
    }
    func didMoveNatively() {
        needsRebind = true
        previous = nil
    }
    func execute(_ request: ParsedCommand) throws {
        // Visual退出后仍保留已有的单次词移动快速通道，避免每个w/e重新传回正文。
        if mode == .normal, request.count == 1,
           [.wordForward, .wordBackward, .wordEnd, .bigWordForward, .bigWordBackward, .bigWordEnd].contains(request.command) {
            let navigator = ChromeWordNavigator(verifyFocus: { try self.provider.verify(self.target) },
                                               trace: { self.provider.trace($0, $1) })
            do {
                let moved = try navigator.move(request.command)
                message = moved ? "Chrome NORMAL · 当前块内词移动" : "已到当前编辑块边界"
                return
            } catch WordNavigationError.unavailable {
                // input/textarea走下面的控件快照；结果不明确的ProviderError不降级重发。
            }
        }
        let before: State
        if needsRebind {
            before = try evaluate(["action": "begin"])
            try validate(before)
            engine.synchronize(before.snapshot)
            needsRebind = false
            provider.trace("web.edit.rebound", ["block": String(before.block == true)])
        } else { before = try read() }
        if mode == .visual, let previous,
           previous.snapshot != before.snapshot || previous.anchor != before.anchor || previous.focus != before.focus {
            throw ProviderError.unavailable("网页选区或正文已由外部改变，已退出接管")
        }
        var candidate = engine
        let intent: EditIntent
        if request.command == .repeatChange {
            guard let replay = history.replay(engine: &candidate, snapshot: before.snapshot, register: clipboard.current()) else {
                message = "没有可重复的已确认修改"; return
            }
            intent = replay
        } else { intent = candidate.execute(request, snapshot: before.snapshot, register: clipboard.current()) }
        // contenteditable的换段由宿主模型管理；验证前不把段落当普通换行修改。
        if case .replace(_, let inserted, _, _) = intent {
            let lineCommand = [.deleteLine, .changeLine, .openAbove, .openBelow, .joinLines].contains(request.command)
            let structural = lineCommand || engine.linewiseVisual || inserted.contains("\n") || inserted.contains("\r")
                || (request.command == .operate && [.moveDown, .moveUp, .documentStart, .documentEnd].contains(request.motion))
            if before.block == true && structural && before.lineEditing != true {
                message = "当前网页段落边界不完整，未执行行编辑；普通移动仍可用"
                provider.trace("web.edit.unsupported", ["command": request.command.rawValue, "reason": "incomplete_line_boundaries"])
                return
            }
            if before.control == true && before.multiline != true && (inserted.contains("\n") || inserted.contains("\r")) {
                message = "单行输入框不支持换行命令"
                provider.trace("web.edit.unsupported", ["command": request.command.rawValue, "reason": "single_line_input"])
                return
            }
        }
        let after = try apply(intent, before: before, candidate: candidate)
        engine = candidate
        history.confirm(request, intent: intent, before: before.snapshot, after: after.snapshot, mode: mode, linewise: engine.linewiseVisual)
        engine.synchronize(after.snapshot)
        previous = after
        if case .copy(let copied, _) = intent {
            message = "已复制\(copied.linewise ? "整行" : "选区")，可按 p/P 粘贴"
            provider.trace("web.copy.confirmed", ["command": request.command.rawValue,
                "linewise": String(copied.linewise), "utf16_count": String(copied.text.utf16.count)])
            return
        }
        if request.command.isMotion && before.snapshot == after.snapshot {
            message = "未移动，已到当前可编辑范围边界"
            provider.trace("web.edit.unchanged", ["command": request.command.rawValue])
            return
        }
        if (request.command == .undo || request.command == .redo) && before.snapshot == after.snapshot {
            message = "未观察到撤销/重做变化，可能为空栈；未重发"
            provider.trace("web.edit.unconfirmed", ["command": request.command.rawValue])
            return
        }
        message = "Chrome \(mode.rawValue.uppercased()) · \(before.block == true ? "当前简单块" : "当前输入框")"
        provider.trace("web.edit.confirmed", ["command": request.command.rawValue, "mode": mode.rawValue,
            "selection": NSStringFromRange(after.snapshot.selection)])
    }

    private func apply(_ intent: EditIntent, before: State, candidate: VimEngine) throws -> State {
        switch intent {
        case .none: return before
        case .select(let range): return try select(range, before: before, engine: candidate)
        case .copy(let value, let caret):
            let after = try select(NSRange(location: caret, length: 0), before: before, engine: candidate)
            try clipboard.copy(value)
            return after
        case .undo, .redo:
            try ensure(before)
            try provider.post(key: 6, flags: intent == .redo ? [.maskCommand, .maskShift] : .maskCommand, target: target)
            return try awaitText(nil, previous: before)
        case .replace(let range, let inserted, let caret, let value):
            let expected = (before.text! as NSString).replacingCharacters(in: range, with: inserted)
            guard expected.utf16.count <= 32768 else { throw ProviderError.unavailable("编辑后超过32K范围限制，未发送修改") }
            let selected = try select(range, before: before, engine: nil)
            try ensure(selected)
            var saved: ClipboardBridge.Saved?
            if inserted.isEmpty {
                if range.length > 0 { try provider.post(key: 51, target: target) }
            } else {
                saved = try clipboard.preparePaste(inserted)
                try clipboard.verify(saved!)
                try ensure(selected)
                try provider.post(key: 9, flags: .maskCommand, target: target)
            }
            let edited = try awaitText(expected, previous: selected)
            if let saved { clipboard.restore(saved) }
            if let value { try clipboard.copy(value) }
            let b = TextBuffer(expected)
            let position = candidate.mode == .insert ? min(caret, expected.utf16.count)
                : b.offsets[b.normalPosition(b.index(atUTF16: caret))]
            return try select(NSRange(location: position, length: 0), before: edited, engine: nil)
        }
    }
    private func ensure(_ state: State) throws {
        let current = try read()
        guard state.snapshot == current.snapshot, state.anchor == current.anchor, state.focus == current.focus else {
            throw ProviderError.unavailable("网页文本或选区已改变，取消编辑")
        }
    }
    private func select(_ range: NSRange, before: State, engine: VimEngine?) throws -> State {
        let backwards = engine.map { $0.mode == .visual && $0.active < ($0.anchor ?? $0.active) } ?? false
        let anchor = backwards ? NSMaxRange(range) : range.location
        let focus = backwards ? range.location : NSMaxRange(range)
        if anchor == before.anchor && focus == before.focus { return before }
        let selected = try evaluate(["action": "select", "expected": before.text!,
            "beforeAnchor": before.anchor!, "beforeFocus": before.focus!, "anchor": anchor, "focus": focus])
        guard selected.status == "ok" else { throw ProviderError.unavailable("网页选择失败：\(selected.status)") }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        repeat {
            let state = try evaluate(["action": "confirm"])
            if state.status == "ok" { try validate(state); return state }
            guard state.status == "pending" else { throw ProviderError.unavailable("网页选区未保持，已退出") }
            Thread.sleep(forTimeInterval: 0.008)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw ProviderError.unavailable("网页选择确认超时，未重复操作")
    }
    private func awaitText(_ expected: String?, previous: State) throws -> State {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        repeat {
            let state = try read()
            if expected.map({ state.text == $0 }) ?? (state.snapshot != previous.snapshot) { return state }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        if expected == nil { return try read() }
        throw ProviderError.unavailable("网页编辑结果未确认，已退出；未重发修改")
    }
    private func validate(_ state: State) throws {
        guard state.status == "ok", let text = state.text, text.utf16.count <= 32768,
              let anchor = state.anchor, let focus = state.focus,
              anchor >= 0, focus >= 0, max(anchor, focus) <= text.utf16.count else {
            throw ProviderError.unavailable("网页编辑状态不可用：\(state.status)")
        }
    }
    private func read() throws -> State {
        let state = try evaluate(["action": "read"])
        try validate(state)
        return state
    }
    private func evaluate(_ fields: [String: Any]) throws -> State {
        try provider.verify(target)
        var request = fields; request["token"] = token
        let data = try JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed])
        let javascript = BrowserEditingScript.source.replacingOccurrences(of: "__REQUEST__", with: String(decoding: data, as: UTF8.self))
        let literal = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Google Chrome\" to execute active tab of front window javascript \"\(literal)\""
        let output: String
        do { output = try AppleScriptBridge.shared.execute(script) }
        catch { throw ProviderError.unavailable("网页请求结果无法确认，已退出接管；未重发操作") }
        try provider.verify(target)
        return try JSONDecoder().decode(State.self, from: Data(output.utf8))
    }
}
