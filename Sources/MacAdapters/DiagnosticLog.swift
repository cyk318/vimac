import Foundation

/// 串行异步写入；到达容量上限后从文件头开始新一轮记录，不生成备份文件。
public final class DiagnosticLog {
    public static let shared = DiagnosticLog(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vimac/vimac.log"), enabled: false)
    public let url: URL
    private let limit: Int
    private let queue = DispatchQueue(label: "Vimac diagnostics", qos: .utility)
    private let gate = NSLock()
    private var pending = 0
    private var dropped = 0
    private var enabled: Bool
    private var handle: FileHandle?
    private var size = 0
    private var sequence = 0
    private let run = UUID().uuidString
    private let formatter = ISO8601DateFormatter()

    public init(url: URL, limit: Int = 30_000_000, enabled: Bool = true) {
        precondition(limit > 0)
        self.url = url
        self.limit = limit
        self.enabled = enabled
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func start() {
        queue.async { self.enabled = true }
        record("app.start", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                             "pid": String(ProcessInfo.processInfo.processIdentifier),
                             "limit_bytes": String(limit)])
    }

    /// 调用方只传诊断元数据，不传正文、剪贴板或原始键盘事件。
    public func record(_ event: String, _ fields: [String: String] = [:]) {
        gate.lock()
        guard pending < 1024 else { dropped += 1; gate.unlock(); return }
        pending += 1
        let lost = dropped
        dropped = 0
        gate.unlock()
        let time = Date()
        queue.async {
            defer { self.gate.lock(); self.pending -= 1; self.gate.unlock() }
            guard self.enabled else { return }
            self.sequence += 1
            var entry = fields
            entry["event"] = event
            entry["time"] = self.formatter.string(from: time)
            entry["run"] = self.run
            entry["seq"] = String(self.sequence)
            if lost > 0 { entry["dropped"] = String(lost) }
            do {
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                data.append(0x0A)
                // 单条异常大记录也不能突破上限。
                guard data.count <= self.limit else { return }
                try self.openIfNeeded()
                if self.size + data.count > self.limit {
                    try self.handle?.truncate(atOffset: 0)
                    try self.handle?.seek(toOffset: 0)
                    self.size = 0
                }
                try self.handle?.write(contentsOf: data)
                self.size += data.count
            } catch {
                // 不让磁盘故障中断编辑，也不输出可能含用户路径的错误详情。
                fputs("Vimac: diagnostic log write failed\n", stderr)
                try? self.handle?.close()
                self.handle = nil
            }
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        size = Int(try handle!.seekToEnd())
    }

    public func flush() { queue.sync { try? handle?.synchronize() } }
    deinit { try? handle?.close() }
}
