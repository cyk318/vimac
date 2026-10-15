import Foundation

enum RangeTextRead {
    case text(String)
    case invalidRange
    case unavailable
}

/// Chromium 富文本的 AXValue 可能包含选区坐标中不存在的段落分隔符。
/// 仅对明确的范围越界收缩长度，通信失败不得被误判为文档结束。
struct RangeTextReader {
    private var previousValue: String?
    private var previousLength: Int?

    mutating func read(value: String, fetch: (Int) -> RangeTextRead) throws -> String {
        let changed = previousValue != value
        var length = changed ? value.utf16.count : previousLength ?? value.utf16.count
        let result = fetch(length)
        let text: String
        switch result {
        case .text(let content): text = content
        case .unavailable:
            throw ProviderError.unavailable("无法读取与选区对应的网页正文，已停止")
        case .invalidRange:
            var low = 0
            var high = length
            // 找到同一坐标系中可读取的完整前缀；不删除换行或猜测偏移补偿。
            while low < high {
                let middle = low + (high - low + 1) / 2
                switch fetch(middle) {
                case .text: low = middle
                case .invalidRange: high = middle - 1
                case .unavailable:
                    throw ProviderError.unavailable("读取网页正文时通信失败，已停止")
                }
            }
            length = low
            guard case .text(let content) = fetch(length) else {
                throw ProviderError.unavailable("无法确认网页正文范围，已停止")
            }
            text = content
        }
        guard text.utf16.count == length else {
            throw ProviderError.unavailable("网页正文与选区长度不一致，已停止")
        }
        // 缩短后的正文必须确实到达末尾；防止把临时错误或旧缓存当成全文。
        if length < value.utf16.count {
            guard case .invalidRange = fetch(length + 1) else {
                throw ProviderError.unavailable("网页正文边界发生变化，已停止")
            }
        }
        previousValue = value
        previousLength = length
        return text
    }
}
