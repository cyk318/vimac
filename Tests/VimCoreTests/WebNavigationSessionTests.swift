import Foundation
import Testing
import VimCore
@testable import MacAdapters

struct WebNavigationSessionTests {
    final class Editor: WebEditingSession {
        var mode: Mode = .normal
        var message = "editor"
        var requests: [Command] = []
        var invalidations = 0
        func begin() throws {}
        func refresh() throws {}
        func didMoveNatively() { invalidations += 1 }
        func execute(_ request: ParsedCommand) throws {
            requests.append(request.command)
            if request.command == .visual { mode = .visual }
            if request.command == .normal { mode = .normal }
        }
    }
    @Test func yankAndRejectedDeleteNeverCaptureNormalArrows() throws {
        for first in [Command.yankLine, .deleteLine] {
            let editor = Editor()
            var caret = NSRange(location: 10, length: 0), keys: [UInt16] = []
            let session = WebNavigationSession(readSelection: { caret }, verifyFocus: {}, sendArrow: {
                keys.append($0); caret.location += $0 == 125 ? 10 : -10
            }, trace: { _, _ in }, makeEditing: { editor })
            try session.begin(); try session.execute(first)
            try session.execute(.moveDown); try session.execute(.moveUp)
            try session.execute(.yankLine)
            #expect(keys == [125, 126])
            #expect(editor.invalidations == 2)
            #expect(editor.requests == [first, .yankLine])
        }
    }
    @Test func visualUsesExactMovementThenEscapeRestoresNativeMovement() throws {
        let editor = Editor()
        var caret = NSRange(location: 0, length: 0), sent = 0
        let session = WebNavigationSession(readSelection: { caret }, verifyFocus: {}, sendArrow: { _ in
            sent += 1; caret.location += 10
        }, trace: { _, _ in }, makeEditing: { editor })
        try session.begin(); try session.execute(.visual); try session.execute(.moveDown)
        #expect(sent == 0)
        #expect(editor.requests == [.visual, .moveDown])
        try session.execute(.normal); try session.execute(.moveDown)
        #expect(sent == 1); #expect(editor.invalidations == 1)
    }
    @Test func countedNativeMovementStopsOnUnconfirmedStep() throws {
        var sent = 0
        let session = WebNavigationSession(readSelection: { NSRange(location: 0, length: 0) },
            verifyFocus: {}, sendArrow: { _ in sent += 1 }, trace: { _, _ in })
        try session.begin(); try session.execute(ParsedCommand(.moveDown, count: 5))
        #expect(sent == 1)
    }
    @Test func staleMotionDoesNotMoveButQueuedInsertStillRuns() throws {
        var sent = 0
        var events: [String] = []
        let session = WebNavigationSession(readSelection: { NSRange(location: 0, length: 0) },
            verifyFocus: {}, sendArrow: { _ in sent += 1 }, trace: { event, _ in events.append(event) },
            moveWord: { _ in sent += 1; return true })
        try session.begin()
        try session.execute(.wordForward, queuedFor: 5)
        try session.execute(.moveDown, queuedFor: 0.251)
        #expect(sent == 0)
        #expect(events.filter { $0 == "command.expired" }.count == 2)
        #expect(session.mode == .normal)
        try session.execute(.insert, queuedFor: 5)
        #expect(session.mode == .insert)
    }
    @Test func startsAndMovesWithoutTextOrWritableSelection() throws {
        var caret = NSRange(location: 900_000, length: 0)
        var keys: [UInt16] = []
        let session = WebNavigationSession(readSelection: { caret }, verifyFocus: {}, sendArrow: {
            keys.append($0)
            caret.location += $0 == 124 || $0 == 125 ? 1 : -1
        }, trace: { _, _ in })
        try session.begin()
        for command in [Command.moveRight, .moveDown, .moveLeft, .moveUp] { try session.execute(command) }
        #expect(keys == [124, 125, 123, 126])
        #expect(session.selection == NSRange(location: 900_000, length: 0))
        #expect(session.mode == .normal)
    }

    @Test func unsupportedCommandsNeverSendKeysOrChangeMode() throws {
        var keys = 0
        var rejected: [String] = []
        let session = WebNavigationSession(readSelection: { NSRange(location: 0, length: 0) },
            verifyFocus: {}, sendArrow: { _ in keys += 1 }, trace: { event, fields in
                if event == "command.unsupported" { rejected.append(fields["command"]!) }
            })
        try session.begin()
        let unsupported = Command.allCases.filter {
            ![Command.moveLeft, .moveRight, .moveDown, .moveUp, .normal, .insert].contains($0)
        }
        for command in unsupported { try session.execute(command) }
        #expect(keys == 0)
        #expect(rejected.count == unsupported.count)
        #expect(session.mode == .normal)
    }

    @Test func insertAndEscapeDoNotReadTextOrSendEscape() throws {
        var caret = NSRange(location: 0, length: 0)
        var sent = 0
        let session = WebNavigationSession(readSelection: { caret }, verifyFocus: {},
            sendArrow: { _ in sent += 1 }, trace: { _, _ in })
        try session.begin()
        try session.execute(.insert)
        caret = NSRange(location: 123, length: 7) // 输入法或宿主暂时持有选区。
        try session.refresh()
        #expect(session.mode == .insert)
        caret.length = 0
        try session.execute(.normal)
        #expect(session.mode == .normal)
        #expect(session.selection == caret)
        #expect(sent == 0)
    }

    @Test func focusChangeAndNonCollapsedSelectionPreventKeyInjection() throws {
        var focused = true
        var caret = NSRange(location: 1, length: 0)
        var sent = 0
        let session = WebNavigationSession(readSelection: { caret }, verifyFocus: {
            if !focused { throw ProviderError.unavailable("焦点已改变") }
        }, sendArrow: { _ in sent += 1 }, trace: { _, _ in })
        try session.begin()
        focused = false
        #expect(throws: ProviderError.self) { try session.execute(.moveLeft) }
        focused = true
        caret.length = 2
        #expect(throws: ProviderError.self) { try session.execute(.moveRight) }
        #expect(sent == 0)
    }

    @Test func unchangedPositionIsUnconfirmedAndNeverRetried() throws {
        var sent = 0
        var events: [String] = []
        let session = WebNavigationSession(readSelection: { NSRange(location: 0, length: 0) },
            verifyFocus: {}, sendArrow: { _ in sent += 1 }, trace: { event, _ in events.append(event) })
        try session.begin()
        try session.execute(.moveLeft)
        #expect(sent == 1)
        #expect(events.contains("web.move.unconfirmed"))
        #expect(!events.contains("web.move.observed"))
    }

    @Test func readFailureAfterSendDoesNotRepeatMovement() throws {
        var sent = 0
        let session = WebNavigationSession(readSelection: {
            if sent > 0 { throw ProviderError.unavailable("读取失败") }
            return NSRange(location: 0, length: 0)
        }, verifyFocus: {}, sendArrow: { _ in sent += 1 }, trace: { _, _ in })
        try session.begin()
        #expect(throws: ProviderError.self) { try session.execute(.moveRight) }
        #expect(sent == 1)
    }
}
