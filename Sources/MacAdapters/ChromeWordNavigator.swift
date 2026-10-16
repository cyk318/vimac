import AppKit
import VimCore

enum WordNavigationError: Error {
    case unavailable(String)
}

/// 在 Chrome 同一个任务中读取段落、计算并移动；正文不再往返于应用与浏览器。
/// 独立确认请求仍核对原元素、原文与落点，不自动重试任何移动。
final class ChromeWordNavigator {
    private let verifyFocus: () throws -> Void
    private let trace: (String, [String: String]) -> Void

    init(verifyFocus: @escaping () throws -> Void, trace: @escaping (String, [String: String]) -> Void) {
        self.verifyFocus = verifyFocus
        self.trace = trace
    }

    func move(_ command: Command) throws -> Bool {
        guard [.wordForward, .wordBackward, .wordEnd].contains(command) else {
            throw WordNavigationError.unavailable("当前命令不是词移动")
        }
        try verifyFocus()
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
            throw WordNavigationError.unavailable("词移动目前仅支持 Chrome 的普通编辑块")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let token = UUID().uuidString
        let moved: Reply
        do {
            moved = try evaluate(["action": "move", "command": command.rawValue, "token": token])
        } catch {
            // 请求可能已经执行，不能保持接管并假设没移动，更不能重发。
            throw ProviderError.unavailable("词移动请求结果不明确，已退出接管；未重复移动")
        }
        if moved.status == "unchanged" { return false }
        guard moved.status == "moved" else {
            if moved.status == "unconfirmed" {
                throw ProviderError.unavailable("词移动结果未确认，已退出接管")
            }
            throw WordNavigationError.unavailable("当前编辑块不支持词移动：\(moved.status)")
        }
        trace("web.word.applied", ["before": String(moved.before ?? -1),
            "requested": String(moved.requested ?? -1), "block_length": String(moved.block_length ?? 0),
            "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        repeat {
            let confirmed: Reply
            do { confirmed = try evaluate(["action": "confirm", "token": token]) }
            catch { throw ProviderError.unavailable("词移动后无法确认光标，已退出接管；未重复移动") }
            if confirmed.status == "ok", confirmed.actual == moved.requested {
                trace("web.word.observed", ["actual": String(confirmed.actual ?? -1),
                    "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
                return true
            }
            guard confirmed.status == "pending" else {
                trace("web.word.rejected", ["status": confirmed.status])
                throw ProviderError.unavailable("宿主未保持请求的词移动位置，已退出接管")
            }
            Thread.sleep(forTimeInterval: 0.004)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw ProviderError.unavailable("页面未及时确认光标，已退出接管；未重复移动")
    }

    private struct Reply: Decodable {
        var status: String
        var before: Int?
        var requested: Int?
        var block_length: Int?
        var actual: Int?
    }

    private func evaluate(_ request: [String: String]) throws -> Reply {
        try verifyFocus()
        // 参数只有固定命令和随机令牌；JSON转义后再放入JS字符串，仍不拼接正文。
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let javascript = BrowserWordScript.source.replacingOccurrences(of: "__REQUEST__",
            with: json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))
        let literal = javascript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // move是一次原子脚本，confirm用页面内随机令牌与真实元素确认身份。
        // 不再分别获取窗口数/窗口ID/标签ID，避免每次调用额外的三次Apple事件往返。
        let source = """
        tell application "Google Chrome"
            return execute active tab of front window javascript "\(literal)"
        end tell
        """
        let started = ProcessInfo.processInfo.systemUptime
        let output = try AppleScriptBridge.shared.execute(source)
        trace("web.bridge.complete", ["phase": request["action"] ?? "unknown",
            "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
        try verifyFocus()
        guard let data = output.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw WordNavigationError.unavailable("页面未返回可用的移动结果")
        }
        return reply
    }
}
