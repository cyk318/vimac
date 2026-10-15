import Foundation
import Testing
import MacAdapters

struct DiagnosticLogTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("vimac.log")
    }

    @Test func overwritesWithinLimitAndKeepsValidLatestRecords() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = DiagnosticLog(url: url, limit: 800)
        for number in 0..<30 {
            log.record("操作", ["number": String(number)])
            log.flush()
            #expect(try Data(contentsOf: url).count <= 800)
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let entries = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
        #expect(entries.last?["number"] == "29")
        #expect(!entries.contains { $0["number"] == "0" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["vimac.log"])
    }

    @Test func restartAppendsAndOversizedExistingFileIsReplaced() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let first = DiagnosticLog(url: url, limit: 1000)
            first.record("first")
            first.flush()
        }
        let second = DiagnosticLog(url: url, limit: 1000)
        second.record("second")
        second.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 2)
        let smaller = DiagnosticLog(url: url, limit: 250)
        smaller.record("latest")
        smaller.flush()
        let data = try Data(contentsOf: url)
        #expect(data.count <= 250)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("latest"))
    }

    @Test func concurrentWritersProduceWholeJSONLines() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = DiagnosticLog(url: url)
        DispatchQueue.concurrentPerform(iterations: 200) { log.record("parallel", ["id": String($0)]) }
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 200)
        let entries = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
        #expect(Set(entries.compactMap { $0["id"] }).count == 200)
        #expect(entries.compactMap { $0["seq"].flatMap(Int.init) } == Array(1...200))
    }
}
