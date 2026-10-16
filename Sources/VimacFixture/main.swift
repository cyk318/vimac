import AppKit
import WebKit

/// 模拟网页 Esc 的副作用；只要泄漏给宿主，就会选中全文并被探针发现。
final class EscapeSensitiveTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selectAll(nil); return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 53 { selectAll(nil); return }
        super.keyUp(with: event)
    }
}

/// 独立进程可真实验证跨应用 AX；不读取或改动用户文档。
final class FixtureDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出试验窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Vimac 试验窗口 · Ctrl+Option+V"
        if CommandLine.arguments.contains("--web") {
            let web = WKWebView(frame: window.contentView!.bounds)
            web.navigationDelegate = self
            window.contentView = web
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // 仅加载固定本地测试内容，不访问网络或用户文档。
            web.loadHTMLString("""
                <html><body><textarea id="editor" style="width:95%;height:400px;font-size:20px">Hello Vimac world!
                Second line 中文 emoji 👩🏽‍💻
                Third line</textarea></body></html>
                """, baseURL: nil)
            return
        }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = EscapeSensitiveTextView(frame: scroll.bounds)
        text.isRichText = false
        text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.string = "Hello Vimac world!\n中文编辑与 emoji 👩🏽‍💻 测试\n\nUse v then j/l to select multiple lines.\nTry yy, p, dd and u.\n"
        scroll.documentView = text
        window.contentView = scroll
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript("const e=document.getElementById('editor');e.focus();e.setSelectionRange(0,0);")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
