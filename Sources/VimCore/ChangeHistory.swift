import Foundation

/// 只在宿主确认后记住修改。Insert 用前后快照确认一次连续插入，不猜测自动改写。
public struct ChangeHistory {
    private var completed: (ParsedCommand, String?, Int?)?
    private var pending: (ParsedCommand, Snapshot, Int?)?
    public init() {}
    public mutating func confirm(_ request: ParsedCommand, intent: EditIntent, before: Snapshot, after: Snapshot, mode: Mode, linewise: Bool = false) {
        if request.command == .normal, let (original, start, visualSize) = pending {
            defer { pending = nil }
            let offset = start.selection.location
            let text = start.text as NSString
            let prefix = text.substring(to: offset), suffix = text.substring(from: offset)
            guard after.text.hasPrefix(prefix), after.text.hasSuffix(suffix),
                  after.text.utf16.count >= start.text.utf16.count else { completed = nil; return }
            let length = after.text.utf16.count - start.text.utf16.count
            completed = (original, (after.text as NSString).substring(with: NSRange(location: offset, length: length)), visualSize)
            return
        }
        guard request.command != .repeatChange else { return }
        var recorded = request
        var visualSize: Int?
        if [.delete, .change].contains(request.command), before.selection.length > 0 {
            let text = (before.text as NSString).substring(with: before.selection)
            if linewise {
                recorded = ParsedCommand(request.command == .change ? .changeLine : .deleteLine,
                    count: max(1, text.filter(\.isNewline).count + (text.last?.isNewline == true ? 0 : 1)))
            } else { visualSize = text.count }
        }
        if mode == .insert { pending = (recorded, after, visualSize); return }
        if case .replace = intent, before.text != after.text { completed = (recorded, nil, visualSize) }
    }
    public mutating func cancelPending() { pending = nil }
    public func replay(engine: inout VimEngine, snapshot: Snapshot, register: Register?) -> EditIntent? {
        guard let (request, insertion, visualSize) = completed else { return nil }
        if let visualSize {
            let b = TextBuffer(snapshot.text)
            let start = b.normalPosition(b.index(atUTF16: snapshot.selection.location))
            engine.mode = .visual; engine.linewiseVisual = false
            engine.anchor = start; engine.active = min(max(0, b.count - 1), start + visualSize - 1)
        }
        let intent = engine.execute(request, snapshot: snapshot, register: register)
        guard let insertion else { return intent }
        let range: NSRange, replacement: String, caret: Int, copied: Register?
        switch intent {
        case .replace(let target, let text, let position, let value):
            range = target; copied = value
            let relative = max(0, min(text.utf16.count, position - target.location))
            replacement = (text as NSString).replacingCharacters(in: NSRange(location: relative, length: 0), with: insertion)
            caret = position + insertion.utf16.count
        case .select(let target): range = target; replacement = insertion; caret = target.location + insertion.utf16.count; copied = nil
        case .none: range = snapshot.selection; replacement = insertion; caret = range.location + insertion.utf16.count; copied = nil
        default: return nil
        }
        let result = (snapshot.text as NSString).replacingCharacters(in: range, with: replacement)
        let b = TextBuffer(result)
        let index = max(0, b.index(atUTF16: caret) - (insertion.isEmpty ? 0 : 1))
        engine.mode = .normal; engine.anchor = nil
        return .replace(range, replacement, caret: b.offsets[index], register: copied)
    }
}
