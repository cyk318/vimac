import Foundation
import Testing
import VimCore

struct SnapshotSynchronizationTests {
    @Test func normalSurvivesHostUpdatesAndStillRecognizesInsert() {
        let before = Snapshot(text: "abc", selection: NSRange(location: 1, length: 0))
        let after = Snapshot(text: "abcd", selection: NSRange(location: 2, length: 0))
        var engine = VimEngine()
        _ = engine.begin(before)
        #expect(!SnapshotSynchronization.mustEndSession(mode: engine.mode, previous: before, current: after))
        engine.synchronize(after)
        #expect(engine.active == 2)
        _ = engine.execute(.insert, snapshot: after, register: nil)
        #expect(engine.mode == .insert)
        _ = engine.execute(.normal, snapshot: after, register: nil)
        #expect(engine.mode == .normal)
    }

    @Test func visualRejectsExternalTextOrSelectionChanges() {
        let before = Snapshot(text: "abc", selection: NSRange(location: 0, length: 2))
        let moved = Snapshot(text: "abc", selection: NSRange(location: 1, length: 1))
        let edited = Snapshot(text: "xyz", selection: before.selection)
        #expect(SnapshotSynchronization.mustEndSession(mode: .visual, previous: before, current: moved))
        #expect(SnapshotSynchronization.mustEndSession(mode: .visual, previous: before, current: edited))
        #expect(!SnapshotSynchronization.mustEndSession(mode: .visual, previous: before, current: before))
        #expect(!SnapshotSynchronization.mustEndSession(mode: .insert, previous: before, current: edited))
    }
}
