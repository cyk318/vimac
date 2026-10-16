import Foundation
import VimCore

/// 网页普通移动使用宿主方向键，词移动由独立的块内适配器处理。
/// 两条路径均不构造 AX 全文快照，不开放正文编辑接口。
final class WebNavigationSession {
    private let readSelection: () throws -> NSRange
    private let verifyFocus: () throws -> Void
    private let sendArrow: (UInt16) throws -> Void
    private let moveWord: ((Command) throws -> Bool)?
    private let trace: (String, [String: String]) -> Void
    private(set) var mode: Mode = .off
    private(set) var selection: NSRange?
    private(set) var message = "网页有限模式 · h/j/k/l 移动，i 输入；Chrome 可用块内 w/b/e"

    init(readSelection: @escaping () throws -> NSRange, verifyFocus: @escaping () throws -> Void,
         sendArrow: @escaping (UInt16) throws -> Void,
         trace: @escaping (String, [String: String]) -> Void,
         moveWord: ((Command) throws -> Bool)? = nil) {
        self.readSelection = readSelection
        self.verifyFocus = verifyFocus
        self.sendArrow = sendArrow
        self.trace = trace
        self.moveWord = moveWord
    }

    convenience init(provider: AccessibilityProvider, target: FocusTarget) {
        let words = ChromeWordNavigator(verifyFocus: { try provider.verify(target) },
                                       trace: { provider.trace($0, $1) })
        self.init(readSelection: { try provider.selection(target) },
                  verifyFocus: { try provider.verify(target) },
                  sendArrow: { try provider.post(key: $0, target: target) },
                  trace: { provider.trace($0, $1) }, moveWord: { try words.move($0) })
    }

    func begin() throws {
        try verifyFocus()
        selection = try caret()
        mode = .normal
        trace("web.session.begin", ["adapter": "native_navigation", "full_text_required": "false",
            "selection": NSStringFromRange(selection!), "commands": "h,j,k,l,i,Esc;Chrome:block-w,b,e"])
    }

    /// Normal 不持有自算偏移；宿主异步更新后继续以真实插入位置为准。
    func refresh() throws {
        try verifyFocus()
        guard mode == .normal else { return }
        let current = try caret()
        if current != selection {
            trace("web.selection.changed", ["actual": NSStringFromRange(current)])
        }
        selection = current
    }

    func execute(_ command: Command) throws {
        guard mode != .off else { return }
        try verifyFocus()
        switch command {
        case .insert:
            selection = try caret()
            mode = .insert
            message = "网页有限模式 · INSERT，Esc 返回移动模式"
            trace("web.mode.changed", ["mode": mode.rawValue])
        case .normal:
            selection = try caret()
            mode = .normal
            message = "网页有限模式 · h/j/k/l 移动，Chrome 块内 w/b/e，i 输入"
            trace("web.mode.changed", ["mode": mode.rawValue])
        case .moveLeft, .moveDown, .moveUp, .moveRight:
            if mode == .normal { try move(command) }
        case .wordForward where moveWord != nil, .wordBackward where moveWord != nil, .wordEnd where moveWord != nil:
            guard mode == .normal, let moveWord else { return }
            do {
                let moved = try moveWord(command)
                selection = try caret()
                message = moved ? "网页有限模式 · 当前编辑块内词移动" : "已到当前编辑块边界；跨块请使用 h/j/k/l"
            } catch WordNavigationError.unavailable(let reason) {
                message = reason
                trace("web.word.unavailable", ["reason": reason])
            }
        default:
            message = "此命令暂不可用；可用 h/j/k/l、i、Esc，Chrome 块内 w/b/e"
            trace("command.unsupported", ["command": command.rawValue, "adapter": "native_navigation"])
        }
    }

    private func caret() throws -> NSRange {
        let current = try readSelection()
        guard current.location >= 0, current.location != NSNotFound, current.length == 0 else {
            throw ProviderError.unavailable("网页有限模式需要单个插入光标，请先收起宿主选区")
        }
        return current
    }

    private func move(_ command: Command) throws {
        let key: UInt16
        switch command {
        case .moveLeft: key = 123
        case .moveRight: key = 124
        case .moveDown: key = 125
        case .moveUp: key = 126
        default: return
        }
        let before = try caret()
        let started = ProcessInfo.processInfo.systemUptime
        trace("web.move.request", ["command": command.rawValue, "before": NSStringFromRange(before)])
        try sendArrow(key)
        // 只等待读回，永不重发；边界不动和宿主未响应不能被描述为移动成功。
        repeat {
            try verifyFocus()
            let current = try caret()
            selection = current
            if current != before {
                message = "网页有限模式 · 宿主方向移动"
                trace("web.move.observed", ["actual": NSStringFromRange(current),
                    "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
                return
            }
            Thread.sleep(forTimeInterval: 0.008)
        } while ProcessInfo.processInfo.systemUptime - started < 0.15
        message = "网页有限模式 · 未观察到光标移动，可能已到边界；未重复发送"
        trace("web.move.unconfirmed", ["actual": selection.map(NSStringFromRange) ?? "unknown"])
    }
}
