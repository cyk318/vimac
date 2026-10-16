import Foundation
import JavaScriptCore
import Testing
import VimCore
@testable import MacAdapters

struct ChromeWordNavigatorTests {
    private func offset(_ command: Command, _ text: String, _ offset: Int) throws -> Int {
        let context = JSContext()!
        context.evaluateScript(BrowserWordScript.algorithm)
        let value = context.objectForKeyedSubscript("wordDestination")!.call(withArguments: [text, offset, command.rawValue])
        guard context.exception == nil, let value, !value.isUndefined else {
            throw WordNavigationError.unavailable("invalid boundary")
        }
        return Int(value.toInt32())
    }

    @Test func browserAlgorithmMatchesNativeCoreAtEveryGraphemeBoundary() {
        let context = JSContext()!
        context.evaluateScript(BrowserWordScript.algorithm)
        let motion = context.objectForKeyedSubscript("wordDestination")!
        let texts = ["", "alpha beta_gamma, delta", "a 👩🏽‍💻 e\u{301} end", "中文测试 后续",
                     "a\r\nb\n\nlast", "  \tword   ", "🇨🇳 1️⃣ #️⃣ café", "αβ ١٢٣ देवनागरी",
                     "\u{feff}word\u{200b}word", "x\u{00a0}y\u{2028}z", "a...!!!???b", "👨‍👩‍👧‍👦💙 x"]
        var checks = 0
        for text in texts {
            let buffer = TextBuffer(text)
            for offset in buffer.offsets {
                for command in [Command.wordForward, .wordBackward, .wordEnd] {
                    var column: Int?
                    let expected = offset == text.utf16.count && command != .wordBackward ? offset
                        : buffer.offsets[buffer.move(command, from: buffer.index(atUTF16: offset), preferredColumn: &column)]
                    let result = motion.call(withArguments: [text, offset, command.rawValue])
                    #expect(context.exception == nil)
                    #expect(Int(result!.toInt32()) == expected, "offset=\(offset) command=\(command)")
                    checks += 1
                }
            }
        }
        print("Browser/native word parity checks: \(checks); no browser or UI used")
    }

    @Test func wordsPunctuationAndUnderscoresUseVimSemantics() throws {
        let text = "alpha beta_gamma, delta"
        #expect(try offset(.wordEnd, text, 0) == 4)
        #expect(try offset(.wordForward, text, 0) == 6)
        #expect(try offset(.wordEnd, text, 6) == 15)
        #expect(try offset(.wordForward, text, 6) == 16)
        #expect(try offset(.wordForward, text, 16) == 18)
        #expect(try offset(.wordBackward, text, 18) == 16)
        #expect(try offset(.wordBackward, text, 15) == 6)
    }

    @Test func emojiAndCombiningMarksNeverSplit() throws {
        let text = "a 👩🏽‍💻 e\u{301} end"
        #expect(try offset(.wordForward, text, 0) == 2)
        #expect(try offset(.wordEnd, text, 0) == 2)
        #expect(try offset(.wordForward, text, 2) == 10)
        #expect(try offset(.wordBackward, text, 10) == 2)
        #expect(throws: WordNavigationError.self) { try offset(.wordForward, text, 3) }
    }

    @Test func emptyAndEndOfBlockDoNotReverseForwardMotion() throws {
        for command in [Command.wordForward, .wordEnd, .wordBackward] {
            #expect(try offset(command, "", 0) == 0)
        }
        #expect(try offset(.wordForward, "last", 4) == 4)
        #expect(try offset(.wordEnd, "last", 4) == 4)
        #expect(try offset(.wordBackward, "last", 4) == 0)
    }

    @Test func wordCapabilityFailureKeepsBasicNavigation() throws {
        var nativeKeys = 0
        var caret = NSRange(location: 0, length: 0)
        let session = WebNavigationSession(readSelection: { caret }, verifyFocus: {},
            sendArrow: { _ in nativeKeys += 1; caret.location += 1 }, trace: { _, _ in },
            moveWord: { _ in throw WordNavigationError.unavailable("unsupported editor") })
        try session.begin()
        try session.execute(.wordForward)
        #expect(session.mode == .normal)
        #expect(nativeKeys == 0)
        try session.execute(.moveRight)
        #expect(nativeKeys == 1)
    }
}
