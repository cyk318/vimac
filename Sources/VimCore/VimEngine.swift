import Foundation

public enum Mode: String { case off, normal, insert, visual }

public enum Command: String, Codable, CaseIterable {
    case moveLeft, moveDown, moveUp, moveRight, wordForward, wordBackward, wordEnd
    case lineStart, lineEnd, deleteCharacter, deleteLine, yankLine, paste, undo
    case insert, visual, normal, yank, delete, change

    public var isMotion: Bool {
        [.moveLeft, .moveDown, .moveUp, .moveRight, .wordForward, .wordBackward,
         .wordEnd, .lineStart, .lineEnd].contains(self)
    }
}

public struct Register: Equatable {
    public var text: String
    public var linewise: Bool
    public init(text: String, linewise: Bool = false) { self.text = text; self.linewise = linewise }
}

public struct Snapshot: Equatable {
    public var text: String
    public var selection: NSRange
    public init(text: String, selection: NSRange) { self.text = text; self.selection = selection }
}

/// 适配器负责应用意图并确认宿主结果；引擎从不直接改宿主或执行 I/O。
public enum EditIntent: Equatable {
    case select(NSRange)
    case copy(Register, caret: Int)
    case replace(NSRange, String, caret: Int, register: Register?)
    case undo
    case none
}

public struct VimEngine {
    public private(set) var mode: Mode = .off
    public private(set) var active = 0
    public private(set) var anchor: Int?
    private var preferredColumn: Int?
    public init() {}

    public mutating func stop() { mode = .off; anchor = nil; preferredColumn = nil }
    public mutating func synchronize(_ snapshot: Snapshot) {
        guard mode == .normal else { return }
        let buffer = TextBuffer(snapshot.text)
        active = buffer.normalPosition(buffer.index(atUTF16: snapshot.selection.location))
    }
    public mutating func begin(_ snapshot: Snapshot) -> EditIntent {
        mode = .normal; anchor = nil; preferredColumn = nil
        let buffer = TextBuffer(snapshot.text)
        active = buffer.normalPosition(buffer.index(atUTF16: snapshot.selection.location))
        return .select(buffer.range(active, active))
    }
    public mutating func execute(_ command: Command, snapshot: Snapshot, register: Register?) -> EditIntent {
        let buffer = TextBuffer(snapshot.text)
        guard mode != .off else { return .none }
        if mode != .visual {
            active = buffer.normalPosition(buffer.index(atUTF16: snapshot.selection.location))
        }
        if command == .normal {
            if mode == .insert { return begin(snapshot) }
            mode = .normal; anchor = nil
            active = buffer.normalPosition(active)
            return .select(buffer.range(active, active))
        }
        if command == .insert { mode = .insert; anchor = nil; return .none }
        if command == .visual {
            if mode == .visual { return execute(.normal, snapshot: snapshot, register: register) }
            mode = .visual; anchor = active
            return .select(visualRange(buffer))
        }
        if command.isMotion {
            active = buffer.move(command, from: active, preferredColumn: &preferredColumn)
            return .select(mode == .visual ? visualRange(buffer) : buffer.range(active, active))
        }
        preferredColumn = nil
        if mode == .visual {
            let range = visualRange(buffer)
            let copied = Register(text: buffer.substring(range))
            if command == .yank || command == .delete || command == .change {
                mode = command == .change ? .insert : .normal
                anchor = nil
                active = buffer.index(atUTF16: range.location)
                if command == .yank { return .copy(copied, caret: range.location) }
                return .replace(range, "", caret: range.location, register: copied)
            }
            return .none
        }
        switch command {
        case .deleteCharacter:
            guard active < buffer.count && !buffer.isNewline(active) else { return .none }
            let range = buffer.range(active, active + 1)
            return .replace(range, "", caret: range.location, register: Register(text: buffer.substring(range)))
        case .deleteLine, .yankLine:
            guard buffer.count > 0 else { return .none }
            let start = buffer.lineStart(active)
            let end = buffer.lineEnd(active)
            let contentRange = buffer.range(start, end < buffer.count ? end + 1 : end)
            var content = buffer.substring(contentRange)
            if end == buffer.count { content += "\n" }
            let copied = Register(text: content, linewise: true)
            if command == .yankLine { return .copy(copied, caret: buffer.offsets[active]) }
            // 无尾换行的末行连同前方分隔符删除；寄存器仍保存行内容。
            let deletionStart = end == buffer.count && start > 0 ? start - 1 : start
            let range = buffer.range(deletionStart, end < buffer.count ? end + 1 : end)
            return .replace(range, "", caret: range.location, register: copied)
        case .paste:
            guard let register, !register.text.isEmpty else { return .none }
            if register.linewise {
                let end = buffer.lineEnd(active)
                let newline = buffer.text.contains("\r\n") ? "\r\n" : "\n"
                var content = register.text
                if !content.hasSuffix("\n") && !content.hasSuffix("\r") { content += newline }
                let hasFollowing = end < buffer.count
                let insertion = hasFollowing ? end + 1 : end
                let prefix = hasFollowing || buffer.count == 0 ? "" : newline
                if !hasFollowing && buffer.count > 0 {
                    if content.hasSuffix("\r\n") { content.removeLast() }
                    else if content.last?.isNewline == true { content.removeLast() }
                }
                let range = buffer.range(insertion, insertion)
                return .replace(range, prefix + content, caret: range.location + prefix.utf16.count, register: nil)
            }
            let insertion = buffer.isNewline(active) ? active : min(buffer.count, active + 1)
            let range = buffer.range(insertion, insertion)
            let pasted = TextBuffer(register.text)
            let caret = range.location + pasted.offsets[max(0, pasted.count - 1)]
            return .replace(range, register.text, caret: caret, register: nil)
        case .undo: return .undo
        default: return .none
        }
    }

    public func cursorRange(in text: String) -> NSRange {
        let buffer = TextBuffer(text)
        let cursor = min(active, buffer.count)
        return buffer.range(cursor, buffer.isNewline(cursor) ? cursor : min(cursor + 1, buffer.count))
    }
    private func visualRange(_ buffer: TextBuffer) -> NSRange {
        let fixed = anchor ?? active
        return buffer.range(min(fixed, active), min(buffer.count, max(fixed, active) + 1))
    }
}
