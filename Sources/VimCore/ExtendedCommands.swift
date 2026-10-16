import Foundation

/// 一条完整命令。motion/argument/object 仅在对应命令中使用，不保存原始按键事件。
public struct ParsedCommand: Equatable {
    public var command: Command
    public var count: Int
    public var explicitCount: Bool
    public var operation: Command?
    public var motion: Command?
    public var argument: String?
    public var object: String?
    public init(_ command: Command, count: Int = 1, explicitCount: Bool = false,
                operation: Command? = nil, motion: Command? = nil, argument: String? = nil, object: String? = nil) {
        self.command = command; self.count = count; self.explicitCount = explicitCount
        self.operation = operation; self.motion = motion; self.argument = argument; self.object = object
    }
}

extension VimEngine {
    /// 先算完整范围，再发出一次编辑意图，计数不会触发多次宿主删除。
    public mutating func execute(_ request: ParsedCommand, snapshot: Snapshot, register: Register?) -> EditIntent {
        guard mode != .off else { return .none }
        let b = TextBuffer(snapshot.text, wordBreakOffsets: snapshot.wordBreakOffsets)
        if mode != .visual { active = b.normalPosition(b.index(atUTF16: snapshot.selection.location)) }
        let n = min(999, max(1, request.count))
        let command = request.command
        if command == .operate {
            var range: NSRange
            var lines = false
            if let object = request.object {
                range = wordObject(object, count: n, buffer: b)
            } else if let motion = request.motion {
                let start = active
                var movement = request; movement.command = motion
                // cw/cW 在非空白词上包含当前词尾，不吞掉下一个词前的空白。
                if request.operation == .change && (motion == .wordForward || motion == .bigWordForward) && b.wordClass(start) != 0 {
                    movement.command = motion == .wordForward ? .wordEnd : .bigWordEnd
                    if n == 1 && (start + 1 == b.count || b.wordClass(start + 1, big: motion == .bigWordForward) != b.wordClass(start, big: motion == .bigWordForward)) {
                        movement.count = 0
                    }
                }
                guard let end = destination(movement, buffer: b) else { return .none }
                lines = [.moveDown, .moveUp, .documentStart, .documentEnd].contains(motion)
                if lines {
                    let upper = b.lineEnd(max(start, end))
                    range = b.range(b.lineStart(min(start, end)), upper < b.count ? upper + 1 : upper)
                } else {
                    let inclusive = [.wordEnd, .bigWordEnd, .lineEnd, .findForward, .findBackward,
                                     .tillForward, .tillBackward].contains(movement.command)
                    let upper = max(start, end) + (inclusive ? 1 : 0)
                    range = b.range(min(start, end), min(b.count, upper))
                }
            } else { return .none }
            if let operation = request.operation { return operate(operation, range: range, linewise: lines, buffer: b) }
            anchor = b.index(atUTF16: range.location)
            active = max(anchor!, b.index(atUTF16: NSMaxRange(range)) - 1)
            mode = .visual; linewiseVisual = false
            return .select(range)
        }
        if command.isMotion || command == .searchForward || command == .searchBackward {
            guard let position = destination(request, buffer: b) else { return .none }
            active = position
            return .select(mode == .visual ? visualRange(b) : b.range(active, active))
        }
        if [.deleteLine, .yankLine, .changeLine].contains(command) {
            if b.count == 0 && command != .changeLine { return .none }
            let end = endOfLines(n, buffer: b)
            return operate(command == .deleteLine ? .delete : command == .yankLine ? .yank : .change,
                range: b.range(b.lineStart(active), end), linewise: true, buffer: b)
        }
        if command == .replaceCharacter {
            guard let argument = request.argument, argument.count == 1, active + n <= b.lineEnd(active) else { return .none }
            let replacement = String(repeating: argument, count: n)
            let caret = b.offsets[active] + TextBuffer(replacement).offsets[n - 1]
            return .replace(b.range(active, active + n), replacement, caret: caret, register: nil)
        }
        if command == .deleteToEnd || command == .changeToEnd {
            var end = b.lineEnd(active)
            for _ in 1..<n where end < b.count { end = b.lineEnd(end + 1) }
            return operate(command == .changeToEnd ? .change : .delete,
                           range: b.range(active, end), linewise: false, buffer: b)
        }
        if [.deleteCharacter, .deleteBackward, .substitute].contains(command) {
            let low = command == .deleteBackward ? max(b.lineStart(active), active - n) : active
            let high = command == .deleteBackward ? active : min(b.lineEnd(active), active + n)
            if low == high && command != .substitute { return .none }
            return operate(command == .substitute ? .change : .delete, range: b.range(low, high), linewise: false, buffer: b)
        }
        if command == .paste || command == .pasteBefore {
            var repeated = register
            if let value = register {
                // 粘贴总量有界，避免一个大剪贴板乘以999造成内存激增。
                guard value.text.utf16.count <= 1_000_000 / n else { return .none }
                repeated = Register(text: String(repeating: value.text, count: n), linewise: value.linewise)
            }
            return executeSingle(command, snapshot: snapshot, register: repeated)
        }
        if [.indent, .outdent, .joinLines, .toggleCase].contains(command) {
            return transform(command, count: n, buffer: b)
        }
        return executeSingle(command, snapshot: snapshot, register: register)
    }

    mutating func extendedEdit(_ command: Command, buffer b: TextBuffer) -> EditIntent {
        let start = b.lineStart(active), end = b.lineEnd(active)
        switch command {
        case .append, .insertStart, .appendEnd:
            var position = command == .append ? min(end, active + 1) : end
            if command == .insertStart { var column: Int?; position = b.move(.firstNonblank, from: active, preferredColumn: &column) }
            mode = .insert; anchor = nil
            return .select(b.range(position, position))
        case .openBelow, .openAbove:
            let newline = b.text.contains("\r\n") ? "\r\n" : "\n"
            let position = command == .openAbove ? start : end
            mode = .insert; anchor = nil
            return .replace(b.range(position, position), newline,
                            caret: b.offsets[position] + (command == .openBelow ? newline.utf16.count : 0), register: nil)
        default: return .none
        }
    }

    private mutating func operate(_ operation: Command, range: NSRange, linewise: Bool, buffer b: TextBuffer) -> EditIntent {
        if range.length == 0 && !linewise && operation != .change { return .none }
        var content = b.substring(range)
        if linewise && content.last?.isNewline != true { content += b.text.contains("\r\n") ? "\r\n" : "\n" }
        let register = Register(text: content, linewise: linewise)
        let oldActive = active
        mode = operation == .change ? .insert : .normal; anchor = nil
        active = b.index(atUTF16: range.location)
        if operation == .yank { return .copy(register, caret: b.offsets[min(oldActive, b.count)]) }
        var deletion = range
        if linewise && operation == .delete && NSMaxRange(range) == b.text.utf16.count && range.location > 0
            && (range.length == 0 || !b.isNewline(b.count - 1)) {
            deletion = b.range(active - 1, b.count)
        }
        let replacement = linewise && operation == .change && (NSMaxRange(range) < b.text.utf16.count || b.substring(range).last?.isNewline == true)
            ? (b.text.contains("\r\n") ? "\r\n" : "\n") : ""
        return .replace(deletion, replacement, caret: deletion.location, register: register)
    }

    private func endOfLines(_ count: Int, buffer b: TextBuffer) -> Int {
        var end = b.lineEnd(active)
        for _ in 1..<max(1, count) where end < b.count { end = b.lineEnd(end + 1) }
        return end < b.count ? end + 1 : end
    }

    private func wordObject(_ object: String, count: Int, buffer b: TextBuffer) -> NSRange {
        guard b.count > 0 else { return b.range(0, 0) }
        let big = object.hasSuffix("W")
        var low = active, high = active
        let kind = b.wordClass(active, big: big)
        while low > b.lineStart(active) && b.wordClass(low - 1, big: big) == kind { low -= 1 }
        while high < b.count && b.wordClass(high, big: big) == kind { high += 1 }
        for _ in 1..<count {
            while high < b.count && b.wordClass(high) == 0 { high += 1 }
            let next = b.wordClass(high, big: big)
            while high < b.count && b.wordClass(high, big: big) == next { high += 1 }
        }
        if object.hasPrefix("a") {
            let previous = high
            while high < b.lineEnd(max(0, high - 1)) && b.wordClass(high) == 0 { high += 1 }
            if high == previous { while low > b.lineStart(low) && b.wordClass(low - 1) == 0 { low -= 1 } }
        }
        return b.range(low, high)
    }

    private mutating func destination(_ request: ParsedCommand, buffer b: TextBuffer) -> Int? {
        var command = request.command
        let n = min(999, max(0, request.count))
        var position = active
        if command == .repeatFind || command == .reverseFind {
            guard var previous = lastFind else { return nil }
            previous.count = n
            if command == .reverseFind {
                let reverse: [Command: Command] = [.findForward: .findBackward, .findBackward: .findForward,
                    .tillForward: .tillBackward, .tillBackward: .tillForward]
                previous.command = reverse[previous.command]!
            }
            let saved = lastFind
            let originalActive = active
            if command == .repeatFind && (previous.command == .tillForward || previous.command == .tillBackward) {
                active += previous.command == .tillForward ? 1 : -1
                active = min(max(0, active), b.count)
            }
            let result = destination(previous, buffer: b)
            lastFind = saved; active = originalActive
            return result
        }
        if [.findForward, .findBackward, .tillForward, .tillBackward].contains(command) {
            guard let needle = request.argument?.first else { return nil }
            let forward = command == .findForward || command == .tillForward
            for _ in 0..<n {
                var candidate = position + (forward ? 1 : -1)
                while candidate >= b.lineStart(active) && candidate < b.lineEnd(active) && b.characters[candidate] != needle {
                    candidate += forward ? 1 : -1
                }
                guard candidate >= b.lineStart(active), candidate < b.lineEnd(active) else { return nil }
                position = candidate
            }
            lastFind = request
            return position + (command == .tillForward ? -1 : command == .tillBackward ? 1 : 0)
        }
        if [.searchForward, .searchBackward, .searchNext, .searchPrevious, .searchWordForward, .searchWordBackward].contains(command) {
            if command == .searchForward || command == .searchBackward {
                if let argument = request.argument, !argument.isEmpty { searchPattern = argument }
                searchBackwards = command == .searchBackward
                searchWholeWord = false
            } else if command == .searchWordForward || command == .searchWordBackward {
                searchPattern = b.substring(wordObject("iw", count: 1, buffer: b))
                searchBackwards = command == .searchWordBackward
                searchWholeWord = true
            }
            guard !searchPattern.isEmpty else { return nil }
            let backwards = command == .searchPrevious ? !searchBackwards : searchBackwards
            let text = b.text as NSString
            let boundaries = Set(b.offsets)
            var matches: [Int] = [], offset = 0
            // 一次扫描建立匹配位置，计数只索引结果，不重复扫描全文999次。
            while offset < text.length {
                let found = text.range(of: searchPattern, options: .literal, range: NSRange(location: offset, length: text.length - offset))
                if found.location == NSNotFound { break }
                if boundaries.contains(found.location), boundaries.contains(NSMaxRange(found)) {
                    let low = b.index(atUTF16: found.location), high = b.index(atUTF16: NSMaxRange(found))
                    let kind = b.wordClass(low)
                    if !searchWholeWord || ((low == 0 || b.wordClass(low - 1) != kind) && (high == b.count || b.wordClass(high) != kind)) {
                        matches.append(low)
                    }
                }
                offset = found.location + max(1, found.length)
            }
            guard !matches.isEmpty else { return nil }
            let first = backwards ? (matches.lastIndex(where: { $0 < position }) ?? matches.count - 1)
                : (matches.firstIndex(where: { $0 > position }) ?? 0)
            let step = (max(1, n) - 1) % matches.count
            return matches[(first + (backwards ? -step : step) + matches.count) % matches.count]
        }
        if (command == .documentStart || command == .documentEnd) && request.explicitCount {
            position = 0
            for _ in 1..<max(1, n) { let end = b.lineEnd(position); if end < b.count { position = end + 1 } }
            return b.normalPosition(position)
        }
        // 行末计数表示第 n 行末；其他移动逐次计算，不产生系统 I/O。
        if command == .lineEnd && n > 1 {
            for _ in 1..<n { position = b.move(.moveDown, from: position, preferredColumn: &preferredColumn) }
            command = .lineEnd
            return b.move(command, from: position, preferredColumn: &preferredColumn)
        }
        for _ in 0..<n {
            let operatorWord = request.operation != nil && [.wordForward, .bigWordForward].contains(command)
            position = b.move(command, from: position, preferredColumn: &preferredColumn, normalize: !operatorWord)
        }
        return position
    }

    private mutating func transform(_ command: Command, count: Int, buffer b: TextBuffer) -> EditIntent {
        var range = mode == .visual ? visualRange(b) : b.range(b.lineStart(active), endOfLines(count, buffer: b))
        if mode == .visual && command != .toggleCase {
            let last = b.lineEnd(max(0, b.index(atUTF16: NSMaxRange(range)) - 1))
            range = b.range(b.lineStart(b.index(atUTF16: range.location)), last < b.count ? last + 1 : last)
        }
        if command == .toggleCase && mode != .visual { range = b.range(active, min(b.lineEnd(active), active + count)) }
        if command == .joinLines && mode != .visual { range = b.range(b.lineStart(active), endOfLines(max(2, count), buffer: b)) }
        let original = b.substring(range)
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        let trailing = original.hasSuffix(newline)
        var lines = original.components(separatedBy: newline)
        if trailing { lines.removeLast() }
        let replacement: String
        switch command {
        case .indent: replacement = lines.map { "    " + $0 }.joined(separator: newline) + (trailing ? newline : "")
        case .outdent:
            replacement = lines.map { line -> String in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(line.prefix(4).prefix(while: { $0 == " " }).count))
            }.joined(separator: newline) + (trailing ? newline : "")
        case .joinLines:
            replacement = lines.enumerated().map { $0.offset == 0 ? $0.element : $0.element.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ") + (trailing ? newline : "")
        default: replacement = original.map { String($0) == String($0).uppercased() ? String($0).lowercased() : String($0).uppercased() }.joined()
        }
        mode = .normal; anchor = nil
        return .replace(range, replacement, caret: range.location, register: nil)
    }
}
