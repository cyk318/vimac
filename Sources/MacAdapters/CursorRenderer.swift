import AppKit
import VimCore

public final class CursorRenderer {
    private let panel: NSPanel
    private let cursor = CursorView()
    public init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = cursor
    }
    public func hide() { panel.orderOut(nil) }
    public func render(mode: Mode, rect: CGRect?, style: CursorStyle) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard mode == .normal || mode == .visual, var rect, let primary = NSScreen.screens.first else { hide(); return }
        rect.origin.y = primary.frame.maxY - rect.maxY
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { hide(); return }
        rect.size.width = style.width.resolve(max(2, rect.width))
        rect.size.height = style.height.resolve(rect.height)
        if style.style == "bar" { rect.size.width = 2 }
        cursor.style = style
        panel.setFrame(rect, display: true)
        cursor.needsDisplay = true
        panel.orderFrontRegardless()
    }
}

private final class CursorView: NSView {
    var style = CursorStyle()
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        if style.style != "outline" {
            NSColor(hex: style.color).withAlphaComponent(style.opacity).setFill()
            path.fill()
        }
        NSColor(hex: style.borderColor).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

extension NSColor {
    public convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
