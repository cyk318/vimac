import AppKit

/// 不激活应用、不接收鼠标，只在状态发生变化时短暂显示。
public final class ModeHUD {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private var dismissal: DispatchWorkItem?

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 112),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.textColor = .labelColor
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 3
        title.frame = NSRect(x: 22, y: 70, width: 416, height: 28)
        subtitle.frame = NSRect(x: 22, y: 14, width: 416, height: 48)
        effect.addSubview(title); effect.addSubview(subtitle)
        panel.contentView = effect
    }

    public func show(title: String, subtitle: String, duration: TimeInterval = 1.8) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissal?.cancel()
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 90))
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    public func hide() { dismissal?.cancel(); panel.orderOut(nil) }
}
