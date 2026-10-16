import Foundation

/// 编辑队列串行复用一个后台解释器，避免每次 Chrome 往返都冷启动 osascript。
/// 协议只走管道；正文和脚本不进入命令参数、临时文件或日志。超时后销毁进程，不重发请求。
final class AppleScriptBridge {
    static let shared = AppleScriptBridge()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var sequence = 0
    private let condition = NSCondition()
    private var received = Data()
    private var ended = false
    private var generation = 0

    func execute(_ source: String, timeout: TimeInterval = 2) throws -> String {
        try startIfNeeded()
        sequence += 1
        // 外层只含 ASCII，避免 availableData 恰好切开一个 UTF-8 字符。
        var request = try JSONSerialization.data(withJSONObject: ["id": sequence, "source": Data(source.utf8).base64EncodedString()])
        request.append(10)
        do { try input?.write(contentsOf: request) }
        catch { stop(); throw WordNavigationError.unavailable("Chrome 通道写入失败，未重试") }
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while !received.contains(10), !ended {
            if !condition.wait(until: deadline) { break }
        }
        guard let newline = received.firstIndex(of: 10) else {
            condition.unlock()
            stop()
            throw WordNavigationError.unavailable("Chrome 响应超时，保留普通移动；未重试")
        }
        let line = received.prefix(upTo: newline)
        received.removeSubrange(...newline)
        condition.unlock()
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              reply["id"] as? Int == sequence else {
            stop()
            throw WordNavigationError.unavailable("Chrome 通道响应不匹配，未重试")
        }
        guard reply["ok"] as? Bool == true, let result = reply["output"] as? String else {
            throw WordNavigationError.unavailable("Chrome 脚本执行失败，请检查自动化及 Apple 事件 JavaScript 权限")
        }
        return result
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        stop()
        condition.lock(); received = Data(); ended = false; let token = generation; condition.unlock()
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        child.arguments = ["-l", "JavaScript", "-e", Self.worker]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        // readabilityHandler 持续排空管道，长段落也不会因管道满而死锁。
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard let self else { return }
            self.condition.lock()
            guard token == self.generation else { self.condition.unlock(); return }
            if bytes.isEmpty || self.received.count + bytes.count > 1_000_000 {
                self.ended = true
                handle.readabilityHandler = nil
            } else { self.received.append(bytes) }
            self.condition.broadcast()
            self.condition.unlock()
        }
        do { try child.run() }
        catch { stdout.fileHandleForReading.readabilityHandler = nil; throw error }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    func stop() {
        condition.lock(); generation += 1; condition.unlock()
        output?.readabilityHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        input = nil; output = nil; process = nil
    }

    deinit { stop() }

    // NSAppleScript 仅在独立进程的主线程使用，既不跨线程调用，也不阻塞 Vimac 主线程。
    private static let worker = #"""
    ObjC.import('Foundation');
    const input=$.NSFileHandle.fileHandleWithStandardInput;
    const output=$.NSFileHandle.fileHandleWithStandardOutput;
    let buffer='';
    function send(value) {
      const s=$(JSON.stringify(value)+'\n');
      output.writeData(s.dataUsingEncoding($.NSUTF8StringEncoding));
    }
    while (true) {
      const chunk=input.availableData;
      if (chunk.length===0) break;
      buffer+=ObjC.unwrap($.NSString.alloc.initWithDataEncoding(chunk,$.NSUTF8StringEncoding));
      let end;
      while ((end=buffer.indexOf('\n'))>=0) {
        const line=buffer.slice(0,end);buffer=buffer.slice(end+1);
        let req;
        try {
          req=JSON.parse(line);
          const error=Ref();
          const source=$.NSString.alloc.initWithDataEncoding($.NSData.alloc.initWithBase64EncodedStringOptions($(req.source),0),$.NSUTF8StringEncoding);
          const script=$.NSAppleScript.alloc.initWithSource(source);
          const value=script.executeAndReturnError(error);
          const text=value.isNil() ? null : ObjC.unwrap(value.stringValue);
          send({id:req.id,ok:text!==null,output:text});
        } catch (_) { send({id:req?req.id:-1,ok:false}); }
      }
    }
    """#
}
