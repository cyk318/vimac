import Foundation
import Testing
import WebKit
import VimCore
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

    @Test func paragraphModelPreservesLineBreaksAndDeleteUsesHostEditing() async throws {
        for tag in ["div", "p"] {
            let view = try await page("<div id='e' contenteditable='true'><\(tag) class='ace-line'><b>one</b></\(tag)><\(tag) class='ace-line'>two</\(tag)><\(tag) class='ace-line'>three</\(tag)></div>")
            _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.firstChild.firstChild.firstChild,0,e.firstChild.firstChild.firstChild,0)")
            let state = try await request(view, ["action":"begin"])
            #expect(state["text"] as? String == "one\ntwo\nthree")
            #expect(state["lineEditing"] as? Bool == true)
            let snapshot = Snapshot(text: state["text"] as! String, selection: NSRange(location: 0, length: 0))
            var engine = VimEngine(); _ = engine.begin(snapshot)
            guard case .replace(let range, _, _, let copied) = engine.execute(.deleteLine, snapshot: snapshot, register: nil) else {
                Issue.record("dd没有产生删除意图"); return
            }
            #expect(copied?.text == "one\n")
            #expect(range == NSRange(location: 0, length: 4))
            _ = try await request(view, ["action":"select","expected":snapshot.text,"beforeAnchor":0,"beforeFocus":0,"anchor":0,"focus":NSMaxRange(range)])
            _ = try await view.evaluateJavaScript("testFrame()")
            #expect(try await request(view, ["action":"confirm"])["status"] as? String == "ok")
            _ = try await view.evaluateJavaScript("document.execCommand('delete')")
            let after = try await request(view, ["action":"read"])
            #expect(after["text"] as? String == "two\nthree", "\(after)")
        }
    }

    @Test func nativeMoveThenRebindCopiesNewParagraphAndSupportsReverseSelection() async throws {
        let view = try await page("<div id='e' contenteditable='true'><div class='ace-line'>one</div><div class='ace-line'>two</div></div>")
        _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.firstChild.firstChild,0,e.firstChild.firstChild,0)")
        _ = try await request(view, ["action":"begin"])
        _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.lastChild.firstChild,1,e.lastChild.firstChild,1)")
        let rebound = try await request(view, ["action":"begin"])
        #expect(rebound["focus"] as? Int == 5)
        let snapshot = Snapshot(text: rebound["text"] as! String, selection: NSRange(location: 5, length: 0))
        var engine = VimEngine(); _ = engine.begin(snapshot)
        #expect(engine.execute(.yankLine, snapshot: snapshot, register: nil) == .copy(Register(text: "two\n", linewise: true), caret: 5))
        let selected = try await request(view, ["action":"select","expected":snapshot.text,"beforeAnchor":5,"beforeFocus":5,"anchor":7,"focus":0])
        #expect(selected["anchor"] as? Int == 7); #expect(selected["focus"] as? Int == 0)
    }

    @Test func emptyParagraphPlaceholderAndLastLineDeletionStayRepresentable() async throws {
        let view = try await page("<div id='e' contenteditable='true'><div>one</div><div><br></div><div>last</div></div>")
        _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.lastChild.firstChild,0,e.lastChild.firstChild,0)")
        let state = try await request(view, ["action":"begin"])
        #expect(state["text"] as? String == "one\n\nlast")
        #expect(state["focus"] as? Int == 5)
        _ = try await request(view, ["action":"select","expected":"one\n\nlast","beforeAnchor":5,"beforeFocus":5,"anchor":4,"focus":9])
        _ = try await view.evaluateJavaScript("testFrame();document.execCommand('delete')")
        let after = try await request(view, ["action":"read"])
        #expect(after["text"] as? String == "one\n", "\(after)")
    }

    @Test func replacedParagraphDuringConfirmationIsStaleEvenWithSameText() async throws {
        let view = try await page("<div id='e' contenteditable='true'><div>one</div><div>two</div></div>")
        _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.firstChild.firstChild,0,e.firstChild.firstChild,0)")
        _ = try await request(view, ["action":"begin"])
        _ = try await request(view, ["action":"select","expected":"one\ntwo","beforeAnchor":0,"beforeFocus":0,"anchor":0,"focus":4])
        _ = try await view.evaluateJavaScript("e.lastChild.replaceWith(e.lastChild.cloneNode(true));getSelection().setBaseAndExtent(e.firstChild.firstChild,0,e.lastChild.firstChild,0);testFrame()")
        #expect(try await request(view, ["action":"confirm"])["status"] as? String == "stale")
    }

    @Test func complexDocumentFallsBackWithoutPretendingItCanDeleteParagraphs() async throws {
        let view = try await page("<div id='e' contenteditable='true'><div class='ace-line'>one</div><table><tr><td>cell</td></tr></table></div>")
        _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.firstChild.firstChild,0,e.firstChild.firstChild,0)")
        let state = try await request(view, ["action":"begin"])
        #expect(state["text"] as? String == "one")
        #expect(state["lineEditing"] as? Bool == false)
    }

    @Test func yankThenLinewisePasteUsesParagraphCoordinates() async throws {
        let view = try await page("<div id='e' contenteditable='true'><div>one</div><div>two</div></div>")
        _ = try await view.evaluateJavaScript("getSelection().setBaseAndExtent(e.firstChild.firstChild,0,e.firstChild.firstChild,0)")
        let state = try await request(view, ["action":"begin"])
        let snapshot = Snapshot(text: state["text"] as! String, selection: NSRange(location: 0, length: 0))
        var engine = VimEngine(); _ = engine.begin(snapshot)
        guard case .copy(let copied, _) = engine.execute(.yankLine, snapshot: snapshot, register: nil),
              case .replace(let range, let inserted, _, _) = engine.execute(.paste, snapshot: snapshot, register: copied) else {
            Issue.record("yy/p没有产生预期意图"); return
        }
        #expect(copied.text == "one\n")
        _ = try await request(view, ["action":"select","expected":snapshot.text,"beforeAnchor":0,"beforeFocus":0,"anchor":range.location,"focus":NSMaxRange(range)])
        let argument = String(decoding: try JSONSerialization.data(withJSONObject: inserted, options: .fragmentsAllowed), as: UTF8.self)
        _ = try await view.evaluateJavaScript("testFrame();document.execCommand('insertText',false,\(argument))")
        let after = try await request(view, ["action":"read"])
        #expect(after["text"] as? String == "one\none\ntwo", "\(after)")
    }
}
