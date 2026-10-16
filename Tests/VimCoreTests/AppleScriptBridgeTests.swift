import Foundation
import Testing
@testable import MacAdapters

/// 只执行纯 AppleScript，不连接 Chrome、不激活窗口、不需要系统自动化权限。
struct AppleScriptBridgeTests {
    @Test func repeatedRoundTripsAndLargeUnicodePayload() throws {
        let bridge = AppleScriptBridge()
        defer { bridge.stop() }
        #expect(try bridge.execute("return \"ready\"") == "ready")
        var timings: [Double] = []
        for index in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            #expect(try bridge.execute("return \"reply-\(index)\"") == "reply-\(index)")
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        timings.sort()
        print("Local warm bridge ms: p50=\(timings[15]), p95=\(timings[28]); no browser involved")
        let text = String(repeating: "中文👩🏽‍💻", count: 5000)
        #expect(try bridge.execute("return \"\(text)\"") == text)
    }

    @Test func timeoutDiscardsLateReplyAndNextCallStartsFresh() throws {
        let bridge = AppleScriptBridge()
        defer { bridge.stop() }
        _ = try bridge.execute("return \"ready\"")
        #expect(throws: WordNavigationError.self) {
            try bridge.execute("delay 1\nreturn \"late\"", timeout: 0.05)
        }
        #expect(try bridge.execute("return \"new-process\"") == "new-process")
    }

    @Test func scriptFailureDoesNotBreakNextRequest() throws {
        let bridge = AppleScriptBridge()
        defer { bridge.stop() }
        #expect(throws: WordNavigationError.self) { try bridge.execute("error \"private detail\"") }
        #expect(try bridge.execute("return \"recovered\"") == "recovered")
    }
}
