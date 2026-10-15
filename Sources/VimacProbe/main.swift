import AppKit
import ApplicationServices
import Carbon
import MacAdapters
import VimCore

// 此探针只操作自己启动的独立试验进程；焦点不匹配就终止。
if CommandLine.arguments.contains("--inspect-native-motion") {
    do {
        let provider = AccessibilityProvider()
        let target = try provider.focus()
        let original = try provider.snapshot(target)
        let moved = try provider.moveWebLine(.moveDown, previous: original, target: target)
        print("native down original=\(original.selection), actual=\(moved.selection), unchanged=\(moved.text == original.text)")
        let restored = try provider.moveWebLine(.moveUp, previous: moved, target: target)
        print("native up actual=\(restored.selection), returnedToOriginal=\(restored.selection == original.selection)")
        exit(0)
    } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
}
if CommandLine.arguments.contains("--inspect-motion") {
    do {
        let provider = AccessibilityProvider()
        let target = try provider.focus()
        let original = try provider.snapshot(target)
        var engine = VimEngine()
        _ = engine.begin(original)
        guard case .select(let requested) = engine.execute(.moveDown, snapshot: original, register: nil) else { exit(1) }
        print("original=\(original.selection), requested=\(requested); content omitted")
        var native = CFRange(location: requested.location, length: requested.length)
        try provider.ensure(original, target: target)
        let result = AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &native)!)
        print("AX set result=\(result.rawValue)")
        var last = original
        for delay in [0.0, 0.01, 0.03, 0.06, 0.1, 0.2] {
            Thread.sleep(forTimeInterval: delay)
            last = try provider.snapshot(target)
            print("afterDelay=\(delay), selection=\(last.selection), textUnchanged=\(last.text == original.text)")
        }
        if last.text == original.text {
            try provider.ensure(last, target: target)
            var restore = CFRange(location: original.selection.location, length: original.selection.length)
            print("restore result=\(AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &restore)!).rawValue)")
        }
        exit(0)
    } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
}
if CommandLine.arguments.contains("--inspect-focus") {
    do {
        let provider = AccessibilityProvider()
        let target = try provider.focus()
        let snapshot = try provider.snapshot(target)
        print("PASS focused editable control: pid=\(target.pid), utf16Count=\(snapshot.text.utf16.count), selection=\(snapshot.selection)")
        print("text content omitted; no selection or text was changed")
        exit(0)
    } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// 字符断言固定使用 ASCII 输入源；测试结束仅在仍为本测试输入源时恢复用户原选择。
let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
let testSource = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
guard TISSelectInputSource(testSource) == noErr else { fatalError("无法设置探针输入源，未执行文本测试") }
let keyboard = KeyboardInterceptor()
let coordinator = SessionCoordinator(keyboard: keyboard)
if CommandLine.arguments.contains("--verbose") {
    coordinator.onUpdate = { mode, _, message, _ in print("STATE \(mode.rawValue): \(message)") }
}
if !CommandLine.arguments.contains("--external-app") { keyboard.start() }
let fixture = Process()
fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("VimacFixture")
try fixture.run()

DispatchQueue.global(qos: .userInitiated).async {
    var exitCode: Int32 = 0
    do {
        let provider = AccessibilityProvider()
        var target: FocusTarget?
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let focused = try? provider.focus(), focused.pid == fixture.processIdentifier { target = focused; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let target else { throw ProviderError.unavailable("未取得试验窗口焦点或权限，未操作其他应用") }
        provider.canProceed = { fixture.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier }
        let original = try provider.snapshot(target)
        guard original.text.hasPrefix("Hello Vimac world!") else { throw ProviderError.unavailable("试验文本与预期不一致") }
        let range = NSRange(location: 0, length: 5)
        try provider.select(range, target: target)
        print("PASS AX read and exact selection")
        guard provider.bounds(NSRange(location: 0, length: 1), target: target) != nil else {
            throw ProviderError.unavailable("试验控件未返回光标位置")
        }
        print("PASS AX glyph bounds")
        let beforeDelete = try provider.snapshot(target)
        try provider.post(key: 51, target: target)
        let deletedText = (original.text as NSString).replacingCharacters(in: range, with: "")
        let deleted = try provider.awaitText(deletedText, previous: beforeDelete, target: target)
        print("PASS native delete")
        try provider.post(key: 6, flags: .maskCommand, target: target)
        _ = try provider.awaitText(original.text, previous: deleted, target: target)
        print("PASS native undo")
        try provider.select(NSRange(location: 0, length: 0), target: target)
        let beforePaste = try provider.snapshot(target)
        let clipboard = ClipboardBridge()
        let saved = try clipboard.preparePaste("测试👩🏽‍💻\n")
        try clipboard.verify(saved)
        try provider.post(key: 9, flags: .maskCommand, target: target)
        _ = try provider.awaitText("测试👩🏽‍💻\n" + original.text, previous: beforePaste, target: target)
        clipboard.restore(saved)
        print("PASS native multiline Unicode paste and conditional clipboard restore")
        do {
            try provider.ensure(original, target: target)
            throw ProviderError.unavailable("陈旧快照未被拒绝")
        } catch ProviderError.unavailable(let message) where message.contains("文本或选区已变化") {
            print("PASS stale snapshot rejected")
        }
        provider.canProceed = { false }
        do {
            try provider.post(key: 51, target: target)
            throw ProviderError.unavailable("已取消会话仍发送了按键")
        } catch ProviderError.unavailable(let message) where message == "会话已取消" {
            print("PASS cancelled session rejected before key injection")
        }
        provider.canProceed = { fixture.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier }
        try provider.select(NSRange(location: 0, length: 0), target: target)
        let beforeKeys = try provider.snapshot(target)
        func send(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
            try provider.verify(target)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
                event.flags = flags
                event.post(tap: .cgSessionEventTap)
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        try send(9, flags: [.maskControl, .maskAlternate])
        try send(37) // l
        guard try provider.snapshot(target).selection.location == 1 else { throw ProviderError.unavailable("全局 l 移动失败") }
        try send(9) // v
        try send(38) // j
        guard try provider.snapshot(target).selection.length > 2 else { throw ProviderError.unavailable("全局 Visual 多行选区失败") }
        try send(53) // Esc
        guard try provider.snapshot(target).selection.length == 0 else { throw ProviderError.unavailable("Visual 退出未收拢选区") }
        // 模拟网页异步更新光标；Normal 必须保留接管，后续 i 不能漏成正文字符。
        try provider.select(NSRange(location: 0, length: 0), target: target)
        Thread.sleep(forTimeInterval: 0.2)
        let beforeModeChange = try provider.snapshot(target)
        try send(34) // i
        let beforeInsert = try provider.snapshot(target)
        guard beforeInsert.text == beforeModeChange.text else {
            throw ProviderError.unavailable("宿主光标更新导致 Normal 提前退出，i 被插入正文")
        }
        print("PASS Normal survives host selection update and consumes i")
        try send(7) // x must reach host in Insert.
        let inserted = try provider.snapshot(target)
        let expectedInsert = (beforeInsert.text as NSString).replacingCharacters(in: beforeInsert.selection, with: "x")
        guard inserted.text == expectedInsert else { throw ProviderError.unavailable("Insert 普通字符未透传") }
        try send(53)
        let afterEscape = try provider.snapshot(target)
        guard afterEscape.selection.length == 0,
              afterEscape.text == inserted.text else {
            throw ProviderError.unavailable("Insert Esc 泄漏给宿主，触发了宿主选区行为")
        }
        print("PASS Insert Esc consumed: host keyDown/keyUp handlers did not select text")
        try send(9, flags: [.maskControl, .maskAlternate])
        let beforeOff = try provider.snapshot(target)
        try send(4) // h must reach host when Off.
        guard try provider.snapshot(target).text == (beforeOff.text as NSString).replacingCharacters(in: beforeOff.selection, with: "h") else {
            throw ProviderError.unavailable("关闭后输入未恢复")
        }
        guard beforeKeys.text != inserted.text else { throw ProviderError.unavailable("插入模式测试未执行") }
        print("PASS global event tap: toggle, l, Visual+j, Esc, Insert passthrough, exit passthrough")
        try send(9, flags: [.maskControl, .maskAlternate])
        let beforeBurst = try provider.snapshot(target)
        for key: CGKeyCode in [34, 7, 0, 49] { // i x a space，无等待模拟快速切换。
            try provider.verify(target)
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!.post(tap: .cgSessionEventTap)
            }
        }
        Thread.sleep(forTimeInterval: 0.4)
        let burstResult = try provider.snapshot(target)
        guard burstResult.text == (beforeBurst.text as NSString).replacingCharacters(in: beforeBurst.selection, with: "xa ") else {
            let start = beforeBurst.selection.location
            let actual = (burstResult.text as NSString).substring(with: NSRange(location: start, length: min(3, burstResult.text.utf16.count - start)))
            throw ProviderError.unavailable("快速 i 后输入丢失或乱序，试验数据字符编码：\(Array(actual.utf16))，增量：\(burstResult.text.utf16.count - beforeBurst.text.utf16.count)")
        }
        try send(9, flags: [.maskControl, .maskAlternate])
        print("PASS rapid Insert transition preserves queued text and space")
        // Off 时 Esc 必须恢复给宿主，验证试验窗口确实具有可观测副作用。
        try send(53)
        let escapedWhileOff = try provider.snapshot(target)
        guard escapedWhileOff.selection.length == escapedWhileOff.text.utf16.count else {
            throw ProviderError.unavailable("关闭状态未恢复宿主 Esc")
        }
        print("PASS Off Esc reaches host and selects text as fixture requires")
    } catch {
        print("FAIL \(error.localizedDescription)")
        exitCode = 1
    }
    if fixture.isRunning { fixture.terminate() }
    let result = exitCode
    DispatchQueue.main.async {
        keyboard.stop()
        let currentSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if CFEqual(currentSource, testSource) { TISSelectInputSource(originalSource) }
        exit(result)
    }
}
app.run()
