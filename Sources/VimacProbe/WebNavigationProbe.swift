import AppKit
import ApplicationServices
import MacAdapters

/// 只对探针启动的网页试验窗口断言；正文只在内存比较，不写日志。
func runWebNavigationProbe(provider: AccessibilityProvider, target: FocusTarget) throws {
    guard provider.isWebEditor(target) else { throw ProviderError.unavailable("试验控件未识别为网页") }
    func text() throws -> String {
        try provider.verify(target)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.element, kAXValueAttribute as CFString, &raw) == .success,
              let value = raw as? String else { throw ProviderError.unavailable("试验断言无法读取文本") }
        return value
    }
    func send(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        try provider.verify(target)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let original = try text()
    guard original.hasPrefix("Hello Vimac world!") else { throw ProviderError.unavailable("网页试验数据不匹配") }
    try send(9, flags: [.maskControl, .maskAlternate])
    try send(37) // l
    guard try provider.selection(target).location == 1, try text() == original else {
        throw ProviderError.unavailable("网页接管或 l 原生移动失败")
    }
    try send(4) // h
    guard try provider.selection(target).location == 0 else { throw ProviderError.unavailable("网页 h 失败") }
    print("PASS web toggle and native h/l without full-text snapshot")
    try send(38) // j
    guard try provider.selection(target).location > 0 else { throw ProviderError.unavailable("网页 j 失败") }
    try send(40) // k
    guard try provider.selection(target).location == 0 else { throw ProviderError.unavailable("网页 k 失败") }
    print("PASS web native j/k")
    for key: CGKeyCode in [7, 9, 14, 13, 11, 2, 2, 35] { try send(key) } // x v e w b dd p
    guard try text() == original, try provider.selection(target) == NSRange(location: 0, length: 0) else {
        throw ProviderError.unavailable("网页禁用命令改变了文本或选区")
    }
    print("PASS web unsupported commands do not edit or select")
    try send(34) // i
    try send(7) // x
    try send(53) // Esc
    guard try text() == "x" + original else { throw ProviderError.unavailable("网页 Insert / Esc 失败") }
    try send(4) // h after inserted x
    guard try provider.selection(target).location == 0 else { throw ProviderError.unavailable("网页 Insert 后移动失败") }
    print("PASS web Insert, Esc and subsequent movement")
    try send(9, flags: [.maskControl, .maskAlternate])
    try send(4) // off h inserts
    guard try text() == "hx" + original else { throw ProviderError.unavailable("网页关闭后输入未恢复") }
    print("PASS web Off restores input")
}
