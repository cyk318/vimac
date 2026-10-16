import Foundation
import Testing
import WebKit
@testable import MacAdapters

/// 不创建窗口、不激活浏览器；仅在内存 WebKit 页面验证真实 DOM 与异步确认协议。
@MainActor
struct BrowserWordScriptTests {
    private func fixture() async throws -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.loadHTMLString("<html><body data-fixture='word'><div contenteditable='true'><div class='ace-line'>alpha beta_gamma, delta</div></div></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if let ready = try? await view.evaluateJavaScript("document.body?.dataset.fixture === 'word'"), ready as? Bool == true {
                _ = try await view.evaluateJavaScript("""
                document.hasFocus=()=>true;
                window.requestAnimationFrame=cb=>{window.testFrame=cb;};
                window.fixtureElement=document.querySelector('.ace-line');
                getSelection().setBaseAndExtent(fixtureElement.firstChild,0,fixtureElement.firstChild,0);
                """)
                return view
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProviderError.unavailable("内存测试页加载超时")
    }

    private func request(_ view: WKWebView, _ action: String, token: String = "test") async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["action":action,"command":"wordEnd","token":token])
        let script = BrowserWordScript.source.replacingOccurrences(of: "__REQUEST__", with: String(data: data, encoding: .utf8)!)
        let result = try await view.evaluateJavaScript(script) as! String
        return try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
    }

    @Test func moveIsAtomicButConfirmationWaitsForFrame() async throws {
        let view = try await fixture()
        let moved = try await request(view, "move")
        #expect(moved["status"] as? String == "moved")
        #expect(moved["requested"] as? Int == 4)
        #expect(moved["text"] == nil) // 响应不带正文。
        #expect(try await request(view, "confirm")["status"] as? String == "pending")
        _ = try await view.evaluateJavaScript("testFrame()")
        #expect(try await request(view, "confirm")["status"] as? String == "ok")
        #expect(try await request(view, "confirm")["status"] as? String == "stale")
    }

    @Test func changedTextOrReplacedElementCannotBeConfirmed() async throws {
        for mutation in ["fixtureElement.firstChild.data='changed'",
                         "fixtureElement.replaceWith(fixtureElement.cloneNode(true))"] {
            let view = try await fixture()
            _ = try await request(view, "move")
            _ = try await view.evaluateJavaScript(mutation + ";testFrame()")
            #expect(try await request(view, "confirm")["status"] as? String == "rejected")
        }
    }

    @Test func wrongTokenDoesNotConfirmAnotherDocument() async throws {
        let view = try await fixture()
        _ = try await request(view, "move")
        _ = try await view.evaluateJavaScript("testFrame()")
        #expect(try await request(view, "confirm", token: "different")["status"] as? String == "stale")
        #expect(try await request(view, "confirm")["status"] as? String == "ok")
    }
}
