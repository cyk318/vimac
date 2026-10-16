import AppKit
import ApplicationServices
import Carbon
import VimCore

public enum ProviderError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { switch self { case .unavailable(let message): return message } }
}

public struct FocusTarget {
    public let element: AXUIElement
    public let pid: pid_t
}

/// 仅在协调器串行队列调用。任何修改都先核对当前焦点与快照，不重试写操作。
public final class AccessibilityProvider {
    public static let eventMarker: Int64 = 0x56494D4143
    private let system = AXUIElementCreateSystemWide()
    private var rangeTextTarget: AXUIElement?
    private var rangeTextReader = RangeTextReader()
    private var loggedTextLengths: String?
    private var optionalMissSession: String?
    private var optionalMisses = Set<String>()
    public private(set) var hasUnmappedParagraphs = false
    public var canProceed: (() -> Bool)?
    var diagnosticContext: [String: String] = [:]
    func trace(_ event: String, _ fields: [String: String] = [:]) {
        DiagnosticLog.shared.record(event, diagnosticContext.merging(fields) { _, new in new })
    }
    public init() { AXUIElementSetMessagingTimeout(system, 0.08) }

    private func value(_ element: AXUIElement, _ attribute: String, optional: Bool = false) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            // 可选属性缺失不是操作失败；每会话保留首条，避免10Hz焦点检查淹没真正错误。
            if optional && (error == .noValue || error == .attributeUnsupported) {
                let session = diagnosticContext["session"]
                if optionalMissSession != session { optionalMissSession = session; optionalMisses.removeAll() }
                guard optionalMisses.insert(attribute + ":" + String(error.rawValue)).inserted else { return nil }
            }
            trace("ax.attribute.failed", ["attribute": attribute, "ax_result": String(error.rawValue)])
            return nil
        }
        return value
    }
    public func focus() throws -> FocusTarget {
        guard AXIsProcessTrusted() else { throw ProviderError.unavailable("请在系统设置中允许 Vimac 使用辅助功能") }
        guard !IsSecureEventInputEnabled() else { throw ProviderError.unavailable("安全输入已开启，Vim 模式已关闭") }
        guard let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw ProviderError.unavailable("当前没有前台应用")
        }
        let application = AXUIElementCreateApplication(foregroundPID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        // Chrome 的系统级焦点可能返回 cannotComplete，而进程级焦点是有效的。
        // 首次读取窗口让延迟构建的浏览器 AX 树就绪，不遍历或输出页面正文。
        var rawFocus = value(application, kAXFocusedUIElementAttribute)
        if rawFocus == nil {
            _ = value(application, kAXWindowsAttribute)
            rawFocus = value(application, kAXFocusedUIElementAttribute)
        }
        guard let raw = rawFocus ?? value(system, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw ProviderError.unavailable("当前没有可编辑的文本框")
        }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.08)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == foregroundPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID else {
            throw ProviderError.unavailable("输入焦点已改变")
        }
        let subrole = value(element, kAXSubroleAttribute, optional: true) as? String
        guard subrole != kAXSecureTextFieldSubrole else { throw ProviderError.unavailable("密码输入框不启用 Vim 模式") }
        var valueWritable = DarwinBoolean(false)
        let explicitlyEditable = value(element, kAXIsEditableAttribute, optional: true) as? Bool
        let enabled = value(element, kAXEnabledAttribute) as? Bool
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueWritable)
        guard enabled != false, explicitlyEditable != false,
              explicitlyEditable == true || valueWritable.boolValue else {
            throw ProviderError.unavailable("当前控件未确认可编辑，保留原始输入")
        }
        return FocusTarget(element: element, pid: pid)
    }
    /// 精确编辑才需要 AX 写选区；网页原生方向移动不依赖这项能力。
    public func requireWritableSelection(_ target: FocusTarget) throws {
        try verify(target)
        var writable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(target.element, kAXSelectedTextRangeAttribute as CFString, &writable)
        trace("capability.selection_write", ["ax_result": String(result.rawValue), "writable": String(writable.boolValue)])
        guard result == .success, writable.boolValue else {
            throw ProviderError.unavailable("当前控件不支持精确选区，保留原始输入")
        }
    }

    /// 只记录能力元数据；声明支持的接口仍可能调用失败，不能据此启用编辑。
    public func traceCapabilities(_ target: FocusTarget) {
        var names: CFArray?
        let result = AXUIElementCopyParameterizedAttributeNames(target.element, &names)
        let parameters = names as? [String] ?? []
        trace("capability.probe", ["role": value(target.element, kAXRoleAttribute) as? String ?? "unknown",
            "subrole": value(target.element, kAXSubroleAttribute) as? String ?? "unknown",
            "parameter_names_result": String(result.rawValue),
            "advertises_range_text": String(parameters.contains(kAXStringForRangeParameterizedAttribute)),
            "advertises_range_bounds": String(parameters.contains(kAXBoundsForRangeParameterizedAttribute)),
            "host_version": NSRunningApplication(processIdentifier: target.pid)?.bundleURL
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "unknown"])
    }

    /// 选区坐标独立读取，不用 AXValue 或 AXStringForRange 反推长度。
    public func selection(_ target: FocusTarget) throws -> NSRange {
        try verify(target)
        guard let raw = value(target.element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            trace("selection.read.failed", ["reason": "missing_or_wrong_type"])
            throw ProviderError.unavailable("当前网页未提供可读取的选区，保留原始输入")
        }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0,
              range.location != NSNotFound, range.length >= 0,
              range.length <= Int.max - range.location else {
            trace("selection.read.failed", ["reason": "invalid_range"])
            throw ProviderError.unavailable("宿主返回的选区无效")
        }
        return NSRange(location: range.location, length: range.length)
    }
    public func verify(_ target: FocusTarget) throws {
        guard canProceed?() ?? true else { throw ProviderError.unavailable("会话已取消") }
        let current = try focus()
        guard current.pid == target.pid, CFEqual(current.element, target.element) else {
            throw ProviderError.unavailable("输入焦点已改变，已取消待执行命令")
        }
    }
    public func snapshot(_ target: FocusTarget) throws -> Snapshot {
        try verify(target)
        if diagnosticContext["operation"] == "begin" {
            trace("snapshot.probe", ["role": value(target.element, kAXRoleAttribute) as? String ?? "unknown",
                "subrole": value(target.element, kAXSubroleAttribute) as? String ?? "unknown"])
        }
        guard let valueText = value(target.element, kAXValueAttribute) as? String,
              let rawRange = value(target.element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else {
            throw ProviderError.unavailable("当前控件未提供可读取的文本与选区")
        }
        guard valueText.utf16.count <= 1_000_000 else { throw ProviderError.unavailable("文本超过 100 万 UTF-16 单元，已退出接管") }
        let text: String
        hasUnmappedParagraphs = false
        if isWebEditor(target) {
            if rangeTextTarget.map({ !CFEqual($0, target.element) }) ?? true {
                rangeTextReader = RangeTextReader()
                rangeTextTarget = target.element
                loggedTextLengths = nil
            }
            text = try rangeTextReader.read(value: valueText) { length in
                let started = ProcessInfo.processInfo.systemUptime
                var range = CFRange(location: 0, length: length)
                guard let parameter = AXValueCreate(.cfRange, &range) else {
                    trace("text.range.failed", ["reason": "parameter_creation", "requested_length": String(length)])
                    return .unavailable
                }
                var result: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(target.element,
                    kAXStringForRangeParameterizedAttribute as CFString, parameter, &result)
                // 不记录正文；保留每次边界探测和真实 AX 错误，区分越界、能力缺失和通信失败。
                trace("text.range.read", ["attribute": kAXStringForRangeParameterizedAttribute,
                    "requested_location": "0", "requested_length": String(length),
                    "value_length": String(valueText.utf16.count), "ax_result": String(error.rawValue),
                    "returned_length": (result as? String).map { String($0.utf16.count) } ?? "none",
                    "result_type": result.map { String(CFGetTypeID($0)) } ?? "none",
                    "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
                if error == .illegalArgument { return .invalidRange }
                guard error == .success, let content = result as? String else { return .unavailable }
                return .text(content)
            }
            let lengths = "\(valueText.utf16.count)/\(text.utf16.count)"
            hasUnmappedParagraphs = valueText.filter(\.isNewline).count != text.filter(\.isNewline).count
            if lengths != loggedTextLengths {
                trace("text.coordinates", ["source": "AXStringForRange", "value_length": String(valueText.utf16.count),
                                           "range_length": String(text.utf16.count), "equal": String(valueText == text)])
                loggedTextLengths = lengths
            }
        } else { text = valueText }
        var range = CFRange()
        guard AXValueGetValue(rawRange as! AXValue, .cfRange, &range), range.location >= 0,
              range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location else {
            throw ProviderError.unavailable("宿主返回的选区无效")
        }
        var wordBreaks = Set<Int>()
        if hasUnmappedParagraphs, valueText.filter({ !$0.isNewline }) == text {
            var offset = 0
            for character in valueText {
                if character.isNewline { wordBreaks.insert(offset) }
                else { offset += String(character).utf16.count }
            }
        }
        return Snapshot(text: text, selection: NSRange(location: range.location, length: range.length),
                        wordBreakOffsets: wordBreaks)
    }
    public func ensure(_ expected: Snapshot, target: FocusTarget) throws {
        let actual = try snapshot(target)
        guard actual == expected else {
            trace("snapshot.mismatch", ["expected_selection": NSStringFromRange(expected.selection),
                                        "actual_selection": NSStringFromRange(actual.selection),
                                        "text_changed": String(actual.text != expected.text)])
            throw ProviderError.unavailable("文本或选区已变化，请重新开启 Vim 模式")
        }
    }
    public func isWebEditor(_ target: FocusTarget) -> Bool {
        var element = target.element
        for _ in 0..<16 {
            if value(element, kAXRoleAttribute) as? String == "AXWebArea" { return true }
            guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = parent as! AXUIElement
        }
        return false
    }

    /// 网页跨段落的 AX offset 可能被宿主修正，Normal 上下移动交给编辑器自己定位。
    public func moveWebLine(_ command: Command, previous: Snapshot, target: FocusTarget) throws -> Snapshot {
        guard command == .moveDown || command == .moveUp, isWebEditor(target) else {
            throw ProviderError.unavailable("当前控件不支持网页原生行移动")
        }
        try ensure(previous, target: target)
        trace("web.move.request", ["selection": NSStringFromRange(previous.selection)])
        try post(key: command == .moveDown ? 125 : 126, target: target)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        repeat {
            let current = try snapshot(target)
            guard current.text == previous.text, current.selection.length == 0 else {
                throw ProviderError.unavailable("行移动时正文或选区发生非预期变化，已停止")
            }
            if current.selection != previous.selection {
                trace("web.move.result", ["selection": NSStringFromRange(current.selection)])
                return current
            }
            Thread.sleep(forTimeInterval: 0.008)
        } while ProcessInfo.processInfo.systemUptime < deadline
        // 文档边界允许位置不变，不重复发送方向键。
        let current = try snapshot(target)
        trace("web.move.timeout", ["selection": NSStringFromRange(current.selection)])
        return current
    }
    public func select(_ range: NSRange, target: FocusTarget) throws {
        try verify(target)
        // 不重复写入相同选区，避免网页编辑器把无实际变化的 AX 写入当作新选择动作。
        let previous = try snapshot(target)
        if previous.selection == range {
            trace("selection.unchanged", ["selection": NSStringFromRange(range)])
            return
        }
        trace("selection.request", ["before": NSStringFromRange(previous.selection),
                                    "requested": NSStringFromRange(range),
                                    "utf16_count": String(previous.text.utf16.count)])
        var native = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &native) else {
            throw ProviderError.unavailable("无法创建请求选区")
        }
        let result = AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, value)
        trace("selection.write", ["ax_result": String(result.rawValue)])
        guard result == .success else {
            throw ProviderError.unavailable("宿主拒绝设置选区")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var observed = previous.selection
        var attempts = 0
        repeat {
            let current = try snapshot(target)
            observed = current.selection
            attempts += 1
            guard current.text == previous.text else { throw ProviderError.unavailable("设置选区期间正文已改变，已停止") }
            if current.selection == range {
                trace("selection.accepted", ["actual": NSStringFromRange(observed), "reads": String(attempts)])
                return
            }
            Thread.sleep(forTimeInterval: 0.008)
        } while ProcessInfo.processInfo.systemUptime < deadline
        trace("selection.rejected", ["requested": NSStringFromRange(range), "actual": NSStringFromRange(observed),
                                     "reads": String(attempts),
                                     "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
        throw ProviderError.unavailable("宿主未采用请求选区，已停止，未继续执行编辑")
    }
    public func post(key: CGKeyCode, flags: CGEventFlags = [], target: FocusTarget) throws {
        try verify(target)
        trace("host.key", ["key_code": String(key), "flags": String(flags.rawValue)])
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            throw ProviderError.unavailable("无法创建编辑按键")
        }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        }
        down.postToPid(target.pid)
        up.postToPid(target.pid)
    }
    /// 模式切换之前已拦截的真实按键按原顺序交还同一输入框，避免快速 i/c 后丢字。
    public func replay(_ event: CGEvent, target: FocusTarget) throws {
        try verify(target)
        guard let down = event.copy(), let up = event.copy() else { throw ProviderError.unavailable("无法恢复输入按键") }
        down.type = .keyDown; up.type = .keyUp
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        down.postToPid(target.pid); up.postToPid(target.pid)
    }

    /// 仅等待读取结果；结果不明确时停止，不二次发送 Delete 或 Paste。
    public func awaitText(_ expected: String?, previous: Snapshot, target: FocusTarget) throws -> Snapshot {
        let deadline = Date().addingTimeInterval(0.3)
        repeat {
            let current = try snapshot(target)
            if let expected {
                if current.text == expected { return current }
            } else if current != previous { return current }
            Thread.sleep(forTimeInterval: 0.008)
        } while Date() < deadline
        if expected == nil { return try snapshot(target) } // 空撤销栈允许无变化。
        throw ProviderError.unavailable("编辑结果未确认，已停止；请检查宿主文本，未自动重试")
    }

    public func bounds(_ range: NSRange, target: FocusTarget) -> CGRect? {
        guard (try? verify(target)) != nil else { return nil }
        var native = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &native) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(target.element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        // 部分宿主会返回滚出可见区域的字符矩形，不能在窗口外绘制覆盖光标。
        if let frame = frame(of: target.element) {
            guard rect.maxY > frame.minY, rect.minY < frame.maxY,
                  rect.maxX >= frame.minX, rect.minX <= frame.maxX else { return nil }
            rect = CGRect(x: max(rect.minX, frame.minX), y: max(rect.minY, frame.minY),
                          width: min(rect.maxX, frame.maxX) - max(rect.minX, frame.minX),
                          height: min(rect.maxY, frame.maxY) - max(rect.minY, frame.minY))
        }
        return rect
    }
    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
