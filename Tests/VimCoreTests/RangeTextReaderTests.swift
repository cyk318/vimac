import Foundation
import Testing
import VimCore
@testable import MacAdapters

struct RangeTextReaderTests {
    private func fetch(_ text: String, length: Int) -> RangeTextRead {
        guard length <= text.utf16.count else { return .invalidRange }
        return .text((text as NSString).substring(to: length))
    }

    @Test func wordMotionsUseSelectionCoordinatesInsteadOfValueNewlines() throws {
        let prefix = String(repeating: "a ", count: 260)
        let actual = prefix + "hello world"
        let value = String(repeating: "\n", count: 31) + actual
        var reader = RangeTextReader()
        let text = try reader.read(value: value) { fetch(actual, length: $0) }
        #expect(text == actual)
        var state = Snapshot(text: text, selection: NSRange(location: 520, length: 0))
        var engine = VimEngine()
        _ = engine.begin(state)
        for (command, expected) in [(Command.wordEnd, 524), (.wordEnd, 530), (.wordBackward, 526), (.moveLeft, 525)] {
            let intent = engine.execute(command, snapshot: state, register: nil)
            #expect(intent == .select(NSRange(location: expected, length: 0)))
            state.selection = NSRange(location: expected, length: 0)
            engine.synchronize(state)
        }
    }

    @Test func inputChangesInvalidateLengthCache() throws {
        var reader = RangeTextReader()
        _ = try reader.read(value: "a\nb") { fetch("ab", length: $0) }
        var calls = 0
        #expect(try reader.read(value: "a\nb") { calls += 1; return fetch("ab", length: $0) } == "ab")
        #expect(calls == 2)
        #expect(try reader.read(value: "a\nb word") { fetch("ab word", length: $0) } == "ab word")
        #expect(try reader.read(value: "a\n") { fetch("a", length: $0) } == "a")
    }

    @Test func communicationFailureIsNotAnEmptyOrTruncatedDocument() {
        var reader = RangeTextReader()
        #expect(throws: ProviderError.self) {
            _ = try reader.read(value: "hello") { _ in .unavailable }
        }
        #expect(throws: ProviderError.self) {
            _ = try reader.read(value: "hello") { $0 == 5 ? .invalidRange : .unavailable }
        }
        #expect(throws: ProviderError.self) {
            _ = try reader.read(value: "hello") { _ in .text("x") }
        }
    }

    @Test func preservesUnicodeAndEmptyText() throws {
        var reader = RangeTextReader()
        let actual = "hello 👩🏽‍💻 world"
        #expect(try reader.read(value: actual) { fetch(actual, length: $0) } == actual)
        #expect(try reader.read(value: "") { fetch("", length: $0) } == "")
    }

    @Test func virtualParagraphBreakDoesNotMergeAdjacentEnglishWords() {
        var engine = VimEngine()
        var state = Snapshot(text: "helloworld", selection: NSRange(location: 0, length: 0), wordBreakOffsets: [5])
        _ = engine.begin(state)
        for (command, expected) in [(Command.wordEnd, 4), (.wordForward, 5), (.wordEnd, 9), (.wordBackward, 5), (.wordBackward, 0)] {
            #expect(engine.execute(command, snapshot: state, register: nil) == .select(NSRange(location: expected, length: 0)))
            state.selection = NSRange(location: expected, length: 0)
        }
    }
}
