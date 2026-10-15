import ApplicationServices
import Foundation

/// 同一应用内换输入框也立即结束会话；100ms 轮询作为不发通知的宿主后备。
final class FocusMonitor {
    private var observer: AXObserver?
    private var application: AXUIElement?
    var onChange: (() -> Void)?

    func start(pid: pid_t) {
        stop()
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, pointer in
            guard let pointer else { return }
            Unmanaged<FocusMonitor>.fromOpaque(pointer).takeUnretainedValue().onChange?()
        }, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(created, application, notification as CFString, context)
        }
        self.observer = created
        self.application = application
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }
    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; application = nil
    }
    deinit { stop() }
}
