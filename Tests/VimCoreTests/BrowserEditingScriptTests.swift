import Foundation
import Testing
import WebKit
@testable import MacAdapters

/// 无窗口WebKit：验证真实DOM/控件选区及身份检查，不操作用户浏览器。
@MainActor
struct BrowserEditingScriptTests {
    private func page(_ body: String) async throws -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.loadHTMLString("<html><body data-fixture='edit'>\(body)</body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("document.body?.dataset.fixture==='edit'")) as? Bool == true {
                _ = try await view.evaluateJavaScript("document.hasFocus=()=>true;window.requestAnimationFrame=cb=>{window.testFrame=cb;};window.e=document.querySelector('#e');e.focus();")
                return view
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProviderError.unavailable("测试页面加载超时")
    }
    private func request(_ view: WKWebView, _ fields: [String: Any]) async throws -> [String: Any] {
        var fields = fields
        if fields["token"] == nil { fields["token"] = "test" }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let result = try await view.evaluateJavaScript(BrowserEditingScript.source.replacingOccurrences(of: "__REQUEST__", with: json)) as! String
        return try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
    }
    @Test func textareaReverseSelectionAndHostDelete() async throws {
        let view = try await page("<textarea id='e'>one\ntwo</textarea>")
        _ = try await view.evaluateJavaScript("e.setSelectionRange(0,0)")
        let initial = try await request(view, ["action":"begin"])
        #expect(initial["text"] as? String == "one\ntwo")
        #expect(initial["multiline"] as? Bool == true)
        let selected = try await request(view, ["action":"select","expected":"one\ntwo", "beforeAnchor":0,"beforeFocus":0,"anchor":4,"focus":0])
        #expect(selected["anchor"] as? Int == 4)
        #expect(try await request(view, ["action":"confirm"])["status"] as? String == "pending")
        _ = try await view.evaluateJavaScript("testFrame()")
        #expect(try await request(view, ["action":"confirm"])["status"] as? String == "ok")
        // execCommand只在测试页模拟宿主编辑，不是产品写正文的实现。
        _ = try await view.evaluateJavaScript("document.execCommand('delete')")
        #expect(try await request(view, ["action":"read"])["text"] as? String == "two")
        // 无窗口WebKit的execCommand('undo')未恢复文本，真实Cmd+Z链路留给前台验收，不能以此模拟为通过。
    }
    @Test func inlineDOMSelectionCrossesTextNodesWithoutChangingMarkup() async throws {
        let view = try await page("<div id='e' contenteditable='true'><b>ab</b><i>cd</i></div>")
        _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.firstChild.firstChild,0,e.firstChild.firstChild,0)")
        #expect(try await request(view, ["action":"begin"])["status"] as? String == "ok")
        let selected = try await request(view, ["action":"select","expected":"abcd","beforeAnchor":0,"beforeFocus":0,"anchor":1,"focus":3])
        #expect(selected["text"] as? String == "abcd")
        #expect(try await view.evaluateJavaScript("getSelection().toString()") as? String == "bc")
        #expect(try await view.evaluateJavaScript("e.innerHTML") as? String == "<b>ab</b><i>cd</i>")
    }
    @Test func staleTextReplacedElementAndTokenCannotSelect() async throws {
        for mutation in ["e.value='changed'", "e.replaceWith(e.cloneNode(true))"] {
            let view = try await page("<input id='e' value='hello'>")
            _ = try await view.evaluateJavaScript("e.setSelectionRange(0,0)")
            _ = try await request(view, ["action":"begin"])
            #expect(try await request(view, ["action":"read","token":"other"])["status"] as? String == "stale")
            _ = try await view.evaluateJavaScript(mutation)
            #expect(try await request(view, ["action":"select","expected":"hello","beforeAnchor":0,"beforeFocus":0,"anchor":0,"focus":2])["status"] as? String == "stale")
        }
    }
    @Test func secureReadonlyLargeAndComplexControlsAreRejected() async throws {
        for html in ["<input id='e' type='password' value='secret'>", "<textarea id='e' readonly>text</textarea>",
                     "<div id='e' contenteditable='true'>abc<br>def</div>"] {
            let view = try await page(html)
            _ = try await view.evaluateJavaScript("if(e.isContentEditable)getSelection().setBaseAndExtent(e.firstChild,0,e.firstChild,0)")
            #expect(try await request(view, ["action":"begin"])["status"] as? String != "ok")
        }
        let view = try await page("<textarea id='e'></textarea>")
        _ = try await view.evaluateJavaScript("e.value='x'.repeat(32769);e.setSelectionRange(0,0)")
        #expect(try await request(view, ["action":"begin"])["status"] as? String == "unsupported")
    }
    @Test func unicodeBoundariesAndLateHostChangesAreVerified() async throws {
        let view = try await page("<textarea id='e'>👩🏽‍💻a</textarea>")
        _ = try await view.evaluateJavaScript("e.setSelectionRange(0,0)")
        _ = try await request(view, ["action":"begin"])
        #expect(try await request(view, ["action":"select","expected":"👩🏽‍💻a","beforeAnchor":0,"beforeFocus":0,"anchor":0,"focus":1])["status"] as? String == "range")
        _ = try await request(view, ["action":"select","expected":"👩🏽‍💻a","beforeAnchor":0,"beforeFocus":0,"anchor":0,"focus":7])
        _ = try await view.evaluateJavaScript("e.setSelectionRange(0,0);testFrame()")
        #expect(try await request(view, ["action":"confirm"])["status"] as? String == "stale")
    }
}
