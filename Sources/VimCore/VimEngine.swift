import Foundation

public enum Mode: String { case off, normal, insert, visual }

public enum Command: String, Codable, CaseIterable {
    case moveLeft, moveDown, moveUp, moveRight, wordForward, wordBackward, wordEnd
    case lineStart, lineEnd, deleteCharacter, deleteLine, yankLine, paste, undo
    case insert, visual, normal, yank, delete, change
    // 大词只按空白分隔；行选择与字符选择共用 Visual 模式。
    case bigWordForward, bigWordBackward, bigWordEnd, firstNonblank, documentStart, documentEnd
    case visualLine, pasteBefore, redo, append, insertStart, appendEnd, openBelow, openAbove
    case deleteBackward, substitute, changeLine, deleteToEnd, changeToEnd, replaceCharacter
    case operate, findForward, findBackward, tillForward, tillBackward, repeatFind, reverseFind
    case repeatChange, joinLines, indent, outdent, toggleCase
    case searchForward, searchBackward, searchNext, searchPrevious, searchWordForward, searchWordBackward

    public var isMotion: Bool {
        [.moveLeft, .moveDown, .moveUp, .moveRight, .wordForward, .wordBackward,
         .wordEnd, .lineStart, .lineEnd, .bigWordForward, .bigWordBackward, .bigWordEnd,
         .firstNonblank, .documentStart, .documentEnd, .findForward, .findBackward,
         .tillForward, .tillBackward, .repeatFind, .reverseFind, .searchNext, .searchPrevious,
         .searchWordForward, .searchWordBackward].contains(self)
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
    public var wordBreakOffsets: Set<Int>
    public init(text: String, selection: NSRange, wordBreakOffsets: Set<Int> = []) {
        self.text = text; self.selection = selection; self.wordBreakOffsets = wordBreakOffsets
    }
}

/// 适配器负责应用意图并确认宿主结果；引擎从不直接改宿主或执行 I/O。
public enum EditIntent: Equatable {
    case select(NSRange)
    case copy(Register, caret: Int)
    case replace(NSRange, String, caret: Int, register: Register?)
    case undo
    case redo
    case none
}

public struct VimEngine {
    public internal(set) var mode: Mode = .off
    public internal(set) var active = 0
    public internal(set) var anchor: Int?
    var preferredColumn: Int?
    public internal(set) var linewiseVisual = false
    var lastFind: ParsedCommand?
    var searchPattern = ""
    var searchBackwards = false
    var searchWholeWord = false
    public init() {}

    public mutating func stop() { mode = .off; anchor = nil; preferredColumn = nil; linewiseVisual = false }
    public mutating func synchronize(_ snapshot: Snapshot) {
        guard mode == .normal else { return }
        let buffer = TextBuffer(snapshot.text)
        active = buffer.normalPosition(buffer.index(atUTF16: snapshot.selection.location))
    }
    public mutating func begin(_ snapshot: Snapshot) -> EditIntent {
        mode = .normal; anchor = nil; preferredColumn = nil; linewiseVisual = false
        let buffer = TextBuffer(snapshot.text)
        active = buffer.normalPosition(buffer.index(atUTF16: snapshot.selection.location))
        return .select(buffer.range(active, active))
    }
    public mutating func execute(_ command: Command, snapshot: Snapshot, register: Register?) -> EditIntent {
        execute(ParsedCommand(command), snapshot: snapshot, register: register)
    }
    mutating func executeSingle(_ command: Command, snapshot: Snapshot, register: Register?) -> EditIntent {
        let buffer = TextBuffer(snapshot.text, wordBreakOffsets: snapshot.wordBreakOffsets)
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
        if command == .visual || command == .visualLine {
            let lines = command == .visualLine
            if mode == .visual && linewiseVisual == lines { return execute(.normal, snapshot: snapshot, register: register) }
            if mode != .visual { anchor = active }
            mode = .visual; linewiseVisual = lines
            return .select(visualRange(buffer))
        }
        if command.isMotion {
            active = buffer.move(command, from: active, preferredColumn: &preferredColumn)
            return .select(mode == .visual ? visualRange(buffer) : buffer.range(active, active))
        }
        preferredColumn = nil
        if mode == .visual {
            let range = visualRange(buffer)
            var content = buffer.substring(range)
            if linewiseVisual && content.last?.isNewline != true { content += snapshot.text.contains("\r\n") ? "\r\n" : "\n" }
            let copied = Register(text: content, linewise: linewiseVisual)
            if command == .yank || command == .delete || command == .change {
                mode = command == .change ? .insert : .normal
                anchor = nil
                active = buffer.index(atUTF16: range.location)
                if command == .yank { return .copy(copied, caret: range.location) }
                var deletion = range
                // 末行无换行时删除前方分隔符；change 保留空行作为输入位置。
                if linewiseVisual && command == .delete && NSMaxRange(range) == snapshot.text.utf16.count && range.location > 0
                    && (range.length == 0 || !buffer.isNewline(buffer.count - 1)) {
                    let start = buffer.index(atUTF16: range.location)
                    deletion = buffer.range(start - 1, buffer.count)
                }
                let replacement = linewiseVisual && command == .change && (NSMaxRange(range) < snapshot.text.utf16.count || buffer.substring(range).last?.isNewline == true)
                    ? (snapshot.text.contains("\r\n") ? "\r\n" : "\n") : ""
                return .replace(deletion, replacement, caret: deletion.location, register: copied)
            }
            return .none
        }
        switch command {
        case .paste, .pasteBefore:
            guard let register, !register.text.isEmpty else { return .none }
            if register.linewise {
                let end = buffer.lineEnd(active)
                let newline = buffer.text.contains("\r\n") ? "\r\n" : "\n"
                var content = register.text
                if content.last?.isNewline != true { content += newline }
                let before = command == .pasteBefore
                let hasFollowing = before || end < buffer.count
                let insertion = before ? buffer.lineStart(active) : (hasFollowing ? end + 1 : end)
                let prefix = hasFollowing || buffer.count == 0 ? "" : newline
                if !hasFollowing && buffer.count > 0 {
                    if content.hasSuffix("\r\n") { content.removeLast() }
                    else if content.last?.isNewline == true { content.removeLast() }
                }
                let range = buffer.range(insertion, insertion)
                return .replace(range, prefix + content, caret: range.location + prefix.utf16.count, register: nil)
            }
            let insertion = command == .pasteBefore || buffer.isNewline(active) ? active : min(buffer.count, active + 1)
            let range = buffer.range(insertion, insertion)
            let pasted = TextBuffer(register.text)
            let caret = range.location + pasted.offsets[max(0, pasted.count - 1)]
            return .replace(range, register.text, caret: caret, register: nil)
        case .undo: return .undo
        case .redo: return .redo
        default: return extendedEdit(command, buffer: buffer)
        }
    }

    public func cursorRange(in text: String) -> NSRange {
        let buffer = TextBuffer(text)
        let cursor = min(active, buffer.count)
        return buffer.range(cursor, buffer.isNewline(cursor) ? cursor : min(cursor + 1, buffer.count))
    }
    func visualRange(_ buffer: TextBuffer) -> NSRange {
        let fixed = anchor ?? active
        if linewiseVisual {
            let end = buffer.lineEnd(max(fixed, active))
            return buffer.range(buffer.lineStart(min(fixed, active)), end < buffer.count ? end + 1 : end)
        }
        return buffer.range(min(fixed, active), min(buffer.count, max(fixed, active) + 1))
    }
}
