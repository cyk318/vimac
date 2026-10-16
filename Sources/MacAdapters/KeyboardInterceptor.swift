import AppKit
import VimCore

public struct KeyInput {
    public let key: String
    public let repeated: Bool
    public let time: TimeInterval
    public let event: CGEvent
}

/// Event tap 回调只访问锁保护的路由快照，不读取 AX 或文件。
public final class KeyboardInterceptor {
    private let lock = NSLock()
    private var mode: Mode = .off
    private var bufferInsert = false
    private var shortcut = try! Shortcut("ctrl+option+v")
    private var swallowed = Set<Int64>()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var requested = false
    public var onKey: ((KeyInput) -> Void)?
    public var onToggle: (() -> Void)?
    public var onCancel: ((String) -> Void)?
    public var onStarted: ((Bool) -> Void)?
    public var onNativeShortcut: (() -> Void)?
    public var onScroll: (() -> Void)?
    public init() {}
    public var isListening: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false
    }
    public var isStarting: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested && tap == nil
    }

    public func update(mode: Mode, shortcut: Shortcut, bufferInsert: Bool = false) {
        lock.lock(); self.mode = mode; self.shortcut = shortcut; self.bufferInsert = bufferInsert; lock.unlock()
    }
    public func disableRouting() { lock.lock(); mode = .off; lock.unlock() }
    public func start() {
        lock.lock()
        guard !requested else { lock.unlock(); return }
        requested = true
        lock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask = [CGEventType.keyDown, .keyUp, .scrollWheel, .leftMouseDown, .rightMouseDown]
                .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<KeyboardInterceptor>.fromOpaque(info).takeUnretainedValue().route(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                self.lock.lock(); self.requested = false; self.lock.unlock()
                self.onStarted?(false); return
            }
            self.lock.lock()
            guard self.requested else { self.lock.unlock(); CFMachPortInvalidate(tap); return }
            self.tap = tap
            self.runLoop = CFRunLoopGetCurrent()
            self.lock.unlock()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.onStarted?(true)
            CFRunLoopRun()
        }
        thread.name = "Vimac keyboard"
        thread.start()
    }
    public func stop() {
        lock.lock()
        let previousTap = tap
        let previousLoop = runLoop
        requested = false
        tap = nil
        runLoop = nil
        lock.unlock()
        if let previousTap { CFMachPortInvalidate(previousTap) }
        if let previousLoop { CFRunLoopStop(previousLoop) }
    }

    private func route(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); mode = .off; swallowed.removeAll(); let currentTap = tap; lock.unlock()
            onCancel?("键盘监听已中断，已退出 Vim 模式")
            if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == AccessibilityProvider.eventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .scrollWheel { onScroll?(); return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown || type == .rightMouseDown {
            lock.lock(); let wasActive = mode != .off; mode = .off; lock.unlock()
            if wasActive { onCancel?("鼠标操作：已退出 Vim 模式") }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        lock.lock()
        if type == .keyUp {
            let consume = swallowed.remove(code) != nil
            lock.unlock()
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        let currentMode = mode
        let currentShortcut = shortcut
        let key = Self.key(code, shifted: event.flags.contains(.maskShift))
        let modifiers = Self.modifiers(event.flags)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let toggle = Self.key(code, shifted: false) == currentShortcut.key && modifiers == currentShortcut.modifiers
        if toggle {
            swallowed.insert(code)
            if currentMode != .off && !repeated { mode = .off }
            lock.unlock()
            if !repeated {
                if currentMode != .off { onCancel?("已关闭") }
                else { onToggle?() }
            }
            return nil
        }
        if currentMode == .off { lock.unlock(); return Unmanaged.passUnretained(event) }
        // Insert 仅记录输入发生和路由方式，不保存可还原正文的键码或字符。
        DiagnosticLog.shared.record("input.route", ["mode": currentMode.rawValue,
            "key": key == "Esc" ? "Esc" : currentMode == .insert ? "<insert>" : "<command>",
            "buffered": String(bufferInsert), "repeated": String(repeated)])
        // Esc 属于 Vim 模式切换，必须同时吞掉按下/松开，不能触发网页自己的取消或选块命令。
        if key == "Esc" {
            swallowed.insert(code)
            mode = .normal
            lock.unlock()
            if !repeated, let copy = event.copy() {
                onKey?(KeyInput(key: "Esc", repeated: false, time: ProcessInfo.processInfo.systemUptime, event: copy))
            }
            return nil
        }
        if currentMode == .insert {
            if bufferInsert {
                swallowed.insert(code)
                lock.unlock()
                if let copy = event.copy() { onKey?(KeyInput(key: key ?? "<unmapped>", repeated: repeated, time: ProcessInfo.processInfo.systemUptime, event: copy)) }
                return nil
            }
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        if modifiers == ["ctrl"], key == "r" {
            swallowed.insert(code)
            lock.unlock()
            if let copy = event.copy() { onKey?(KeyInput(key: "Ctrl+r", repeated: repeated, time: ProcessInfo.processInfo.systemUptime, event: copy)) }
            return nil
        }
        if !modifiers.isDisjoint(with: ["cmd", "ctrl", "option"]) {
            mode = .off
            lock.unlock()
            onNativeShortcut?()
            return Unmanaged.passUnretained(event)
        }
        swallowed.insert(code)
        lock.unlock()
        if let copy = event.copy() { onKey?(KeyInput(key: key ?? "<unmapped>", repeated: repeated, time: ProcessInfo.processInfo.systemUptime, event: copy)) }
        return nil
    }

    private static func modifiers(_ flags: CGEventFlags) -> Set<String> {
        var result = Set<String>()
        for (flag, name) in [(CGEventFlags.maskControl, "ctrl"), (.maskAlternate, "option"), (.maskCommand, "cmd"), (.maskShift, "shift")] {
            if flags.contains(flag) { result.insert(name) }
        }
        return result
    }
    private static func key(_ code: Int64, shifted: Bool) -> String? {
        let keys: [Int64: String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",
            12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",
            24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",
            36:"Return", 49:" ", 51:"Backspace", 37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",50:"`",53:"Esc"]
        guard let base = keys[code] else { return nil }
        if !shifted || base == "Esc" { return base }
        let shiftedKeys = ["1":"!", "2":"@", "3":"#", "4":"$", "5":"%", "6":"^", "7":"&", "8":"*", "9":"(", "0":")", "-":"_", "=":"+", "[":"{", "]":"}", ";":":", "'":"\"", ",":"<", ".":">", "/":"?", "`":"~", "\\":"|"]
        return shiftedKeys[base] ?? base.uppercased()
    }
}
