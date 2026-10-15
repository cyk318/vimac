import AppKit
import VimCore

/// 只保留一个内存寄存器；外部剪贴板变化后不再沿用行型标记。
public final class ClipboardBridge {
    private let pasteboard = NSPasteboard.general
    private var register: Register?
    private var registerVersion = -1
    public init() {}

    public func current() -> Register? {
        if pasteboard.changeCount == registerVersion { return register }
        return pasteboard.string(forType: .string).map { Register(text: $0) }
    }
    public func copy(_ value: Register) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(value.text, forType: .string) else { throw ProviderError.unavailable("无法写入剪贴板") }
        register = value; registerVersion = pasteboard.changeCount
    }

    public struct Saved {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let temporaryVersion: Int
        let previousRegister: Register?
        let wasInternal: Bool
    }
    public func preparePaste(_ text: String) throws -> Saved {
        let wasInternal = pasteboard.changeCount == registerVersion
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ProviderError.unavailable("无法准备粘贴内容") }
        return Saved(items: items, temporaryVersion: pasteboard.changeCount, previousRegister: register, wasInternal: wasInternal)
    }
    public func verify(_ saved: Saved) throws {
        guard pasteboard.changeCount == saved.temporaryVersion else { throw ProviderError.unavailable("剪贴板已被其他应用修改，取消粘贴") }
    }
    /// 只有宿主文本已确认且剪贴板仍归本操作所有时恢复。
    public func restore(_ saved: Saved) {
        guard pasteboard.changeCount == saved.temporaryVersion else { return }
        let items = saved.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
        register = saved.previousRegister
        registerVersion = saved.wasInternal ? pasteboard.changeCount : -1
    }
}
