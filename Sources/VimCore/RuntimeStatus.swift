import Foundation

/// 进程运行、监听就绪和文本编辑模式是不同状态，不能用 OFF 混为一谈。
public enum ListenerStatus: Equatable {
    case needsAccessibility
    case needsInputMonitoring
    case starting
    case ready
    case failed
}

public struct RuntimeStatus {
    public var listener: ListenerStatus = .starting
    public var mode: Mode = .off
    public var detail = "正在启动键盘监听"
    public var shortcut = "ctrl+option+v"
    public init() {}

    public var menuTitle: String {
        switch listener {
        case .needsAccessibility, .needsInputMonitoring: return "Vimac · 待授权"
        case .starting: return "Vimac · 启动中"
        case .failed: return "Vimac · 监听异常"
        case .ready: return mode == .off ? "Vimac · 就绪" : "Vimac · " + mode.rawValue.uppercased()
        }
    }
    public var headline: String {
        switch listener {
        case .needsAccessibility: return "Vimac 正在运行 · 需要辅助功能权限"
        case .needsInputMonitoring: return "Vimac 正在运行 · 需要输入监控权限"
        case .starting: return "Vimac 正在启动监听"
        case .failed: return "Vimac 正在运行 · 键盘监听未就绪"
        case .ready:
            switch mode {
            case .off: return "Vimac 已就绪 · 原始输入"
            case .normal: return "NORMAL · 普通模式"
            case .insert: return "INSERT · 插入模式"
            case .visual: return "VISUAL · 选择模式"
            }
        }
    }
    public var guidance: String {
        switch listener {
        case .needsAccessibility:
            return "在系统设置 → 隐私与安全性 → 辅助功能中开启 Vimac。授权后会自动重新连接，无需再次点击启动。"
        case .needsInputMonitoring:
            return "在系统设置 → 隐私与安全性 → 输入监控中开启 Vimac。授权后会自动重新连接。"
        case .starting: return "请稍候，正在连接全局键盘监听。"
        case .failed: return "监听创建失败。请检查权限；若刚重新构建应用，请退出旧进程并重新授权。"
        case .ready:
            switch mode {
            case .off: return "点击文本框后按 \(shortcut) 进入 Vim；再次按此快捷键恢复原始输入。"
            case .normal: return "h j k l 移动 · i 输入 · v 选择 · \(shortcut) 退出"
            case .insert: return "正常输入文本 · Esc 返回 NORMAL"
            case .visual: return "移动扩展选区 · y 复制 · d 删除 · c 修改 · Esc 取消"
            }
        }
    }

    public mutating func updateEditor(mode: Mode, detail: String) {
        self.mode = mode
        // 焦点切换不能把“缺少权限”覆盖成模糊的“已关闭”。
        if listener == .ready { self.detail = detail }
    }
}
