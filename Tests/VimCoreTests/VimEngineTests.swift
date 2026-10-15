import Testing
import Foundation
import VimCore

struct VimEngineTests {
    private func snapshot(_ text: String, _ offset: Int = 0) -> Snapshot {
        Snapshot(text: text, selection: NSRange(location: offset, length: 0))
    }
    private func run(_ commands: [Command], text: String, offset: Int = 0) -> (Snapshot, VimEngine, Register?) {
        var state = snapshot(text, offset)
        var engine = VimEngine()
        var register: Register?
        _ = engine.begin(state)
        for command in commands {
            let intent = engine.execute(command, snapshot: state, register: register)
            switch intent {
            case .select(let range): state.selection = range
            case .copy(let copied, let caret): register = copied; state.selection = NSRange(location: caret, length: 0)
            case .replace(let range, let inserted, let caret, let copied):
                if let copied { register = copied }
                state.text = (state.text as NSString).replacingCharacters(in: range, with: inserted)
                let buffer = TextBuffer(state.text)
                let position = engine.mode == .insert ? min(caret, state.text.utf16.count) : buffer.offsets[buffer.normalPosition(buffer.index(atUTF16: caret))]
                state.selection = NSRange(location: position, length: 0)
            default: break
            }
            engine.synchronize(state)
        }
        return (state, engine, register)
    }
    @Test func testGraphemeDeletionDoesNotSplitEmojiOrCombiningMark() {
        #expect(run([.deleteCharacter], text: "👩🏽‍💻a").0.text == "a")
        #expect(run([.deleteCharacter], text: "e\u{301}x").0.text == "x")
        let buffer = TextBuffer("👩🏽‍💻a")
        #expect(buffer.index(atUTF16: 2) == 0)
        #expect(buffer.range(0, 1).length == "👩🏽‍💻".utf16.count)
    }
    @Test func testWordsAndPunctuation() {
        #expect(run([.wordForward], text: "one, two").0.selection.location == 3)
        #expect(run([.wordForward, .wordForward], text: "one, two").0.selection.location == 5)
        #expect(run([.wordBackward], text: "one two", offset: 5).0.selection.location == 4)
        #expect(run([.wordEnd], text: "one two").0.selection.location == 2)
        #expect(run([.wordEnd, .wordEnd], text: "one two").0.selection.location == 6)
    }
    @Test func testVerticalMotionPreservesDesiredColumn() {
        #expect(run([.moveDown, .moveDown], text: "abcdef\nx\n123456", offset: 4).0.selection.location == 13)
        #expect(run([.moveUp], text: "abc\nxyz", offset: 6).0.selection.location == 2)
    }
    @Test func testHorizontalAndLineBoundaries() {
        #expect(run([.moveLeft], text: "a\nb", offset: 2).0.selection.location == 2)
        #expect(run([.moveRight], text: "a\nb").0.selection.location == 0)
        #expect(run([.lineEnd], text: "abc\nx").0.selection.location == 2)
        #expect(run([.lineStart], text: "abc\nx", offset: 2).0.selection.location == 0)
    }
    @Test func testVisualCanCrossAnchorAndDeleteMultipleLines() {
        let selected = run([.visual, .moveRight, .moveLeft, .moveLeft], text: "abcd", offset: 1)
        #expect(selected.0.selection == NSRange(location: 0, length: 2))
        let deleted = run([.visual, .moveDown, .delete], text: "abc\ndef\nghi")
        #expect(deleted.0.text == "ef\nghi")
        #expect(deleted.2?.text == "abc\nd")
        #expect(deleted.1.mode == .normal)
    }
    @Test func testVisualYankChangeAndCancel() {
        let copied = run([.visual, .moveRight, .yank], text: "abc")
        #expect(copied.2?.text == "ab")
        #expect(copied.0.text == "abc")
        let changed = run([.visual, .moveRight, .change], text: "abc")
        #expect(changed.0.text == "c")
        #expect(changed.1.mode == .insert)
        #expect(run([.visual, .moveRight, .normal], text: "abc").0.selection == NSRange(location: 1, length: 0))
    }
    @Test func testLineDeletionAndPasteAtEOF() {
        #expect(run([.deleteLine], text: "one\ntwo", offset: 4).0.text == "one")
        #expect(run([.deleteLine], text: "one\ntwo").0.text == "two")
        #expect(run([.yankLine, .paste], text: "one").0.text == "one\none")
        #expect(run([.yankLine, .paste], text: "one\n").0.text == "one\none\n")
        #expect(run([.deleteLine, .paste], text: "only").0.text == "only\n")
        #expect(run([.deleteLine], text: "one\n", offset: 4).0.text == "one")
    }
    @Test func testCRLFAndEmptyDocument() {
        #expect(run([.deleteLine], text: "one\r\ntwo").0.text == "two")
        #expect(run([.yankLine, .paste], text: "one\r\ntwo", offset: 5).0.text == "one\r\ntwo\r\ntwo")
        let empty = run([.visual, .moveDown, .delete, .deleteLine, .wordEnd], text: "")
        #expect(empty.0.text == "")
        #expect(empty.0.selection == NSRange(location: 0, length: 0))
    }
    @Test func testCharacterPasteAndInsertTransition() {
        #expect(run([.deleteCharacter, .paste], text: "abc").0.text == "bac")
        #expect(run([.insert, .normal], text: "abc").1.mode == .normal)
        var engine = VimEngine()
        let input = snapshot("abc")
        _ = engine.begin(input)
        #expect(engine.execute(.undo, snapshot: input, register: nil) == .undo)
        engine.stop()
        #expect(engine.execute(.deleteCharacter, snapshot: input, register: nil) == .none)
    }
    @Test func testEveryMotionStaysAtGraphemeBoundary() {
        for text in ["", "\n", "中文 abc!\r\n👩🏽‍💻e\u{301}", "a\n\nb\n"] {
            let buffer = TextBuffer(text)
            for position in 0...buffer.count {
                for command in Command.allCases where command.isMotion {
                    var preferred: Int?
                    let result = buffer.move(command, from: position, preferredColumn: &preferred)
                    #expect((0...buffer.count).contains(result))
                    #expect(Range(buffer.range(result, result), in: text) != nil)
                }
            }
        }
    }
}
