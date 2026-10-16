import AppKit
import VimCore

enum WordNavigationError: Error {
    case unavailable(String)
}

struct BrowserBlock: Codable, Equatable {
    let text: String
    let offset: Int
    let path: [Int]
    let url: String
}

/// 词移动只读取当前编辑块；文本、DOM 偏移和落点始终在浏览器同一坐标系内。
/// 不使用 AX 全文，不模拟 Option+方向，不修改 DOM 正文或宿主撤销栈。
final class ChromeWordNavigator {
    private let verifyFocus: () throws -> Void
    private let trace: (String, [String: String]) -> Void

    init(verifyFocus: @escaping () throws -> Void, trace: @escaping (String, [String: String]) -> Void) {
        self.verifyFocus = verifyFocus
        self.trace = trace
    }

    static func destination(_ command: Command, block: BrowserBlock) throws -> Int {
        guard [.wordForward, .wordBackward, .wordEnd].contains(command),
              block.text.utf16.count <= 32_768 else {
            throw WordNavigationError.unavailable("当前编辑块过大，暂不支持词移动")
        }
        let buffer = TextBuffer(block.text)
        guard buffer.offsets.contains(block.offset) else {
            throw WordNavigationError.unavailable("当前光标不在完整字符边界")
        }
        if command != .wordBackward, block.offset == block.text.utf16.count { return block.offset }
        var column: Int?
        let index = buffer.move(command, from: buffer.index(atUTF16: block.offset), preferredColumn: &column)
        return buffer.offsets[index]
    }

    func move(_ command: Command) throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let initial = try evaluate(["action": "read"])
        guard initial.status == "ok", let block = initial.block else {
            throw WordNavigationError.unavailable("当前编辑块不支持词移动：\(initial.status)")
        }
        let destination = try Self.destination(command, block: block)
        trace("web.word.request", ["source": "chrome_dom_block", "command": command.rawValue,
            "block_length": String(block.text.utf16.count), "before": String(block.offset),
            "requested": String(destination)])
        if destination == block.offset { return false }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(block))
        let applied: Reply
        do {
            applied = try evaluate(["action": "select", "expected": encoded, "offset": destination],
                                   window: initial.window, tab: initial.tab)
        } catch {
            throw ProviderError.unavailable("词移动请求结果不明确，已退出接管；未重复设置光标")
        }
        guard applied.status == "ok" else {
            if applied.status == "stale" {
                throw WordNavigationError.unavailable("页面或光标已变化，本次未移动")
            }
            throw ProviderError.unavailable("词移动结果未确认，已退出接管；未重复设置光标")
        }
        // selectionchange 会异步触发宿主模型更新，必须重新向浏览器读取，不能只信同步返回。
        Thread.sleep(forTimeInterval: 0.025)
        let confirmed: Reply
        do {
            confirmed = try evaluate(["action": "read"], window: initial.window, tab: initial.tab)
        } catch {
            throw ProviderError.unavailable("词移动后无法确认光标，已退出接管；未重复设置光标")
        }
        guard confirmed.status == "ok", let actual = confirmed.block,
              actual.text == block.text, actual.path == block.path, actual.url == block.url,
              actual.offset == destination else {
            trace("web.word.rejected", ["requested": String(destination),
                "actual": confirmed.block.map { String($0.offset) } ?? "unknown"])
            throw ProviderError.unavailable("宿主未保持请求的词移动位置，已退出接管")
        }
        trace("web.word.observed", ["actual": String(destination),
            "elapsed_ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
        return true
    }

    private struct Reply: Decodable {
        var status: String
        var block: BrowserBlock?
        var window: String = ""
        var tab: String = ""

        enum CodingKeys: String, CodingKey { case status, block }
    }

    private func evaluate(_ request: [String: Any], window: String? = nil, tab: String? = nil) throws -> Reply {
        try verifyFocus()
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
            throw WordNavigationError.unavailable("词移动目前仅支持 Chrome 的普通编辑块")
        }
        let payload = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
        let javascript = Self.script.replacingOccurrences(of: "__REQUEST__", with: payload)
        // 通过标准输入传脚本，正文既不进入进程参数，也不进入日志或临时文件。
        let literal = javascript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let identityCheck = window.flatMap { w in tab.map { t in
            "if wid is not \"\(w)\" or tid is not \"\(t)\" then return \"stale\""
        } } ?? ""
        let source = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return "stale"
            set wid to (id of front window) as text
            set tid to (id of active tab of front window) as text
            \(identityCheck)
            set resultJSON to execute active tab of front window javascript "\(literal)"
            return (wid as text) & linefeed & (tid as text) & linefeed & resultJSON
        end tell
        """
        let output = try Self.runAppleScript(source)
        try verifyFocus()
        if output == "stale" { return Reply(status: "stale") }
        let parts = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, Int(parts[0]) != nil, Int(parts[1]) != nil,
              let data = String(parts[2]).data(using: .utf8),
              var reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw WordNavigationError.unavailable("页面已变化或未返回可用的编辑块")
        }
        reply.window = String(parts[0])
        reply.tab = String(parts[1])
        return reply
    }

    private static func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // 系统错误可能包含脚本正文，不允许直接透传或落日志。
        process.standardError = FileHandle.nullDevice
        try process.run()
        let reader = ScriptOutput()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            reader.data = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            process.terminate()
            throw WordNavigationError.unavailable("Chrome 响应超时，保留普通移动；未重试")
        }
        guard group.wait(timeout: .now() + 0.2) == .success, process.terminationStatus == 0,
              reader.data.count < 1_000_000, let text = String(data: reader.data, encoding: .utf8) else {
            throw WordNavigationError.unavailable("请允许 Vimac 自动化控制 Chrome，并在 Chrome“显示 → 开发者”启用“允许 Apple 事件中的 JavaScript”")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class ScriptOutput: @unchecked Sendable { var data = Data() }

    // 文本节点被富文本 span 切分也使用统一 UTF-16 偏移；复杂对象、换行标签和嵌套编辑器拒绝处理。
    static let script = #"""
    (() => {
      const req = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__REQUEST__'), c => c.charCodeAt(0))));
      const response = (status, block) => JSON.stringify({status, block, window:0, tab:0});
      const s = window.getSelection();
      if (!document.hasFocus() || !s || !s.isCollapsed || !s.anchorNode) return response('no_caret');
      let e = s.anchorNode.nodeType === 1 ? s.anchorNode : s.anchorNode.parentElement;
      while (e && e.getAttribute('contenteditable') !== 'true') {
        if (e.getAttribute('contenteditable') === 'false') return response('readonly');
        e = e.parentElement;
      }
      if (!e || !e.isContentEditable || !e.contains(s.anchorNode)) return response('unsupported_editor');
      // 飞书编辑块可包含多个 ace-line；只在当前实际段落内移动，不能拼接段落文字。
      const paragraph=(s.anchorNode.nodeType===1?s.anchorNode:s.anchorNode.parentElement).closest('.ace-line');
      if (paragraph && e.contains(paragraph)) e=paragraph;
      if (e.querySelector('[contenteditable],br,img,svg,canvas,input,textarea,table,iframe,div,p,li')) return response('complex_block');
      const text = e.textContent;
      if (text.length > 32768) return response('large_block');
      const path = []; for (let n=e; n && n!==document; n=n.parentNode) path.unshift(Array.prototype.indexOf.call(n.parentNode.childNodes,n));
      const r = document.createRange(); r.selectNodeContents(e); r.setEnd(s.anchorNode,s.anchorOffset);
      const block = {text, offset:r.toString().length, path, url:location.href};
      if (req.action === 'read') return response('ok',block);
      const old=req.expected;
      if (!old || old.text!==text || old.offset!==block.offset || old.url!==block.url || JSON.stringify(old.path)!==JSON.stringify(path)) return response('stale');
      if (!Number.isInteger(req.offset) || req.offset<0 || req.offset>text.length) return response('invalid_offset');
      const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);
      let left=req.offset, node;
      while ((node=walker.nextNode())) {
        if (left<=node.data.length) {
          s.setBaseAndExtent(node,left,node,left);
          const actual=document.createRange();actual.selectNodeContents(e);actual.setEnd(s.anchorNode,s.anchorOffset);
          return response(s.isCollapsed && actual.toString().length===req.offset ? 'ok' : 'unconfirmed');
        }
        left-=node.data.length;
      }
      return response('unconfirmed');
    })()
    """#
}
