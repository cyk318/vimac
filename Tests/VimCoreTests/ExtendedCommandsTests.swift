import Foundation
import Testing
import VimCore

struct ExtendedCommandsTests {
    struct Editor {
        var engine = VimEngine()
        var parser = KeyParser()
        var history = ChangeHistory()
        var state: Snapshot
        var register: Register?
        var time = 0.0
        init(_ text: String, at offset: Int = 0) {
            state = Snapshot(text: text, selection: NSRange(location: offset, length: 0))
            _ = engine.begin(state)
        }
        mutating func keys(_ sequence: [String]) {
            for key in sequence {
                time += 0.01
                let request = parser.parse(key, time: time, repeated: false, mappings: Configuration().mappings(for: engine.mode))
                if let request { execute(request) }
            }
        }
        mutating func execute(_ request: ParsedCommand) {
            let before = state
            let intent = request.command == .repeatChange
                ? history.replay(engine: &engine, snapshot: state, register: register) ?? .none
                : engine.execute(request, snapshot: state, register: register)
            switch intent {
            case .select(let range): state.selection = range
            case .copy(let value, let caret): register = value; state.selection = NSRange(location: caret, length: 0)
            case .replace(let range, let text, let caret, let value):
                state.text = (state.text as NSString).replacingCharacters(in: range, with: text)
                if let value { register = value }
                let b = TextBuffer(state.text)
                let position = engine.mode == .insert ? min(caret, state.text.utf16.count)
                    : b.offsets[b.normalPosition(b.index(atUTF16: caret))]
                state.selection = NSRange(location: position, length: 0)
            default: break
            }
            history.confirm(request, intent: intent, before: before, after: state, mode: engine.mode, linewise: engine.linewiseVisual)
            engine.synchronize(state)
        }
        mutating func type(_ text: String) {
            state.text = (state.text as NSString).replacingCharacters(in: state.selection, with: text)
            state.selection = NSRange(location: state.selection.location + text.utf16.count, length: 0)
        }
    }

    @Test func bigWordsKeepPunctuationTogether() {
        var small = Editor("foo.bar baz")
        small.keys(["w"]); #expect(small.state.selection.location == 3)
        var big = Editor("foo.bar baz")
        big.keys(["E"]); #expect(big.state.selection.location == 6)
        big.keys(["W"]); #expect(big.state.selection.location == 8)
        big.keys(["B"]); #expect(big.state.selection.location == 0)
    }
    @Test func visualLineCanReverseSwitchAndYank() {
        var e = Editor("abc\ndef\nghi", at: 5)
        e.keys(["V", "k"])
        #expect(e.state.selection == NSRange(location: 0, length: 8))
        e.keys(["v"]); #expect(e.state.selection == NSRange(location: 1, length: 5))
        e.keys(["V", "y"])
        #expect(e.register == Register(text: "abc\ndef\n", linewise: true))
        #expect(e.engine.mode == .normal)
    }
    @Test func countedLineDeleteAndPasteBefore() {
        var e = Editor("one\ntwo\nthree")
        e.keys(["2", "d", "d"])
        #expect(e.state.text == "three")
        #expect(e.register?.text == "one\ntwo\n")
        e.keys(["P"]); #expect(e.state.text == "one\ntwo\nthree")
        e.keys(["G", "d", "d"]); #expect(e.state.text == "one\ntwo")
    }
    @Test func operatorsMultiplyCountsAndEscapeCancels() {
        var e = Editor("a b c d e f g")
        e.keys(["2", "d", "3", "w"]); #expect(e.state.text == "g")
        var p = KeyParser()
        for key in ["9", "9", "9", "9"] { _ = p.parse(key, time: 1, repeated: false, mappings: Configuration.normalKeys) }
        #expect(p.message.contains("999"))
        _ = p.parse("d", time: 2, repeated: false, mappings: Configuration.normalKeys)
        #expect(p.parse("Esc", time: 2.1, repeated: false, mappings: Configuration.normalKeys)?.command == .normal)
        #expect(p.parse("w", time: 2.2, repeated: false, mappings: Configuration.normalKeys)?.command == .wordForward)
    }
    @Test func changeWordAndTextObjectsHaveDifferentWhitespaceRules() {
        var cw = Editor("foo bar")
        cw.keys(["c", "w"]); #expect(cw.state.text == " bar"); #expect(cw.engine.mode == .insert)
        var dw = Editor("foo bar")
        dw.keys(["d", "w"]); #expect(dw.state.text == "bar")
        var object = Editor("foo.bar baz", at: 5)
        object.keys(["c", "i", "W"]); #expect(object.state.text == " baz")
        var around = Editor("foo bar baz", at: 5)
        around.keys(["d", "a", "w"]); #expect(around.state.text == "foo baz")
        var last = Editor("a b")
        last.keys(["c", "w"]); #expect(last.state.text == " b")
    }
    @Test func findTillAndInclusiveOperator() {
        var e = Editor("abc:def:ghi")
        e.keys(["t", ":"]); #expect(e.state.selection.location == 2)
        e.keys(["0", "d", "f", ":"]); #expect(e.state.text == "def:ghi")
        e.keys(["f", ":", ","]); #expect(e.state.selection.location == 3)
        var repeated = Editor("abc:def:ghi")
        repeated.keys(["t", ":", ";"]); #expect(repeated.state.selection.location == 6)
    }
    @Test func insertEntrypointsAndGraphemeReplacement() {
        var e = Editor("  abc\nxyz", at: 3)
        e.keys(["I"]); #expect(e.state.selection.location == 2)
        e.keys(["Esc", "A"]); #expect(e.state.selection.location == 5)
        e.keys(["Esc", "O"]); #expect(e.state.text == "\n  abc\nxyz"); #expect(e.state.selection.location == 0)
        var r = Editor("👩🏽‍💻abc")
        r.keys(["r", "é"]); #expect(r.state.text == "éabc"); #expect(r.engine.mode == .normal)
        var counted = Editor("👩🏽‍💻abc")
        counted.keys(["2", "r", "X"])
        #expect(counted.state.text == "XXbc"); #expect(counted.state.selection.location == 1)
    }
    @Test func changingLineKeepsOneEditableLineAndCRLF() {
        var e = Editor("one\r\ntwo")
        e.keys(["c", "c"]); #expect(e.state.text == "\r\ntwo"); #expect(e.engine.mode == .insert)
        var tail = Editor("one\ntwo", at: 4)
        tail.keys(["S"]); #expect(tail.state.text == "one\n")
        var trailing = Editor("a\nb\n", at: 2)
        trailing.keys(["d", "d"]); #expect(trailing.state.text == "a\n")
        var trailingChange = Editor("a\nb\n", at: 2)
        trailingChange.keys(["c", "c"]); #expect(trailingChange.state.text == "a\n\n")
    }
    @Test func literalSearchWrapsAndCanBeCancelled() {
        var e = Editor("foo bar foo")
        e.keys(["/", "f", "o", "o", "Return"]); #expect(e.state.selection.location == 8)
        e.keys(["n"]); #expect(e.state.selection.location == 0)
        e.keys(["N"]); #expect(e.state.selection.location == 8)
        e.keys(["/", "b", "Esc"]); #expect(e.state.selection.location == 8)
        var word = Editor("foo foobar foo")
        word.keys(["*"]); #expect(word.state.selection.location == 11)
    }
    @Test func repeatOnlyUsesConfirmedEditAndCapturesInsert() {
        var e = Editor("one two three")
        e.keys(["d", "w", "."]); #expect(e.state.text == "three")
        var change = Editor("foo bar baz")
        change.keys(["c", "w"]); change.type("X"); change.keys(["Esc", "w", "."])
        #expect(change.state.text == "X X baz")
        #expect(change.engine.mode == .normal)
        var visual = Editor("abcdef")
        visual.keys(["v", "l", "d", "."]); #expect(visual.state.text == "ef")
        var lines = Editor("a\nb\nc")
        lines.keys(["V", "d", "."]); #expect(lines.state.text == "c")
    }
    @Test func transformsAndRedoAreExplicit() {
        var e = Editor("one\n  two\nthree")
        e.keys(["J"]); #expect(e.state.text == "one two\nthree")
        e.keys([">", ">"]); #expect(e.state.text.hasPrefix("    one"))
        e.keys(["<", "<"]); #expect(e.state.text.hasPrefix("one"))
        e.keys(["~"]); #expect(e.state.text.hasPrefix("One"))
        #expect(e.engine.execute(ParsedCommand(.redo), snapshot: e.state, register: nil) == .redo)
    }
    @Test func defaultsValidateAndCountsCannotBecomeCustomLiteralKeys() throws {
        try Configuration().validate()
        var e = Editor("one\ntwo\nthree")
        e.keys(["2", "G"]); #expect(e.state.selection.location == 4)
        e.keys(["g", "g"]); #expect(e.state.selection.location == 0)
        e.keys(["v", "i", "w"]); #expect(e.state.selection == NSRange(location: 0, length: 3))
    }
}
