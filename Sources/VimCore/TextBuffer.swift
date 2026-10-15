import Foundation

/// 在字素边界计算 Vim 位置；只有系统适配边界使用 UTF-16 offset。
public struct TextBuffer {
    public let text: String
    public let characters: [Character]
    public let offsets: [Int]

    public init(_ text: String) {
        self.text = text
        characters = Array(text)
        var positions = [0]
        for character in characters { positions.append(positions.last! + String(character).utf16.count) }
        offsets = positions
    }

    public var count: Int { characters.count }
    public func index(atUTF16 offset: Int) -> Int {
        var lower = 0
        var upper = offsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if offsets[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
    public func isNewline(_ index: Int) -> Bool {
        index >= 0 && index < count && characters[index].isNewline
    }
    public func lineStart(_ index: Int) -> Int {
        var cursor = min(max(0, index), count)
        while cursor > 0 && !isNewline(cursor - 1) { cursor -= 1 }
        return cursor
    }
    public func lineEnd(_ index: Int) -> Int {
        var cursor = min(max(0, index), count)
        while cursor < count && !isNewline(cursor) { cursor += 1 }
        return cursor
    }
    public func normalPosition(_ index: Int) -> Int {
        let cursor = min(max(index, 0), count)
        let start = lineStart(cursor)
        return cursor == lineEnd(cursor) && cursor > start ? cursor - 1 : cursor
    }
    public func range(_ start: Int, _ end: Int) -> NSRange {
        let low = min(max(0, start), count)
        let high = min(max(low, end), count)
        return NSRange(location: offsets[low], length: offsets[high] - offsets[low])
    }
    public func substring(_ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }
    private func wordClass(_ index: Int) -> Int {
        guard index < count else { return 0 }
        let character = characters[index]
        if character.isWhitespace { return 0 }
        if character.isLetter || character.isNumber || character == "_" { return 1 }
        return 2
    }
    public func move(_ command: Command, from index: Int, preferredColumn: inout Int?) -> Int {
        var cursor = min(max(0, index), count)
        let start = lineStart(cursor)
        let end = lineEnd(cursor)
        if command != .moveUp && command != .moveDown { preferredColumn = nil }
        switch command {
        case .moveLeft: cursor = max(start, cursor - 1)
        case .moveRight: cursor = min(max(start, end - 1), cursor + 1)
        case .lineStart: cursor = start
        case .lineEnd: cursor = max(start, end - 1)
        case .moveUp, .moveDown:
            let column = preferredColumn ?? (cursor - start)
            preferredColumn = column
            if command == .moveUp, start > 0 {
                let previous = lineStart(start - 1)
                cursor = min(previous + column, max(previous, start - 2))
            } else if command == .moveDown, end < count {
                let next = end + 1
                cursor = min(next + column, max(next, lineEnd(next) - 1))
            }
        case .wordForward:
            let kind = wordClass(cursor)
            while cursor < count && wordClass(cursor) == kind { cursor += 1 }
            while cursor < count && wordClass(cursor) == 0 { cursor += 1 }
        case .wordBackward:
            cursor = max(0, cursor - 1)
            while cursor > 0 && wordClass(cursor) == 0 { cursor -= 1 }
            let kind = wordClass(cursor)
            while cursor > 0 && wordClass(cursor - 1) == kind { cursor -= 1 }
        case .wordEnd:
            cursor = min(count, cursor + 1)
            while cursor < count && wordClass(cursor) == 0 { cursor += 1 }
            let kind = wordClass(cursor)
            while cursor + 1 < count && wordClass(cursor + 1) == kind { cursor += 1 }
        default: break
        }
        return normalPosition(cursor)
    }
}
