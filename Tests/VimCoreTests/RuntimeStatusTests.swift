import Testing
import VimCore

struct RuntimeStatusTests {
    @Test func permissionFailureSurvivesFocusChange() {
        var status = RuntimeStatus()
        status.listener = .needsAccessibility
        status.detail = "请开启辅助功能权限"
        status.updateEditor(mode: .off, detail: "焦点或系统会话已变化")
        #expect(status.menuTitle == "Vimac · 待授权")
        #expect(status.detail == "请开启辅助功能权限")
    }
    @Test func runningAndEditingAreDifferentStates() {
        var status = RuntimeStatus()
        status.listener = .ready
        #expect(status.menuTitle == "Vimac · 就绪")
        for mode in [Mode.normal, .insert, .visual] {
            status.updateEditor(mode: mode, detail: "切换")
            #expect(status.menuTitle.contains(mode.rawValue.uppercased()))
            #expect(status.headline.contains(mode.rawValue.uppercased()))
        }
        status.listener = .failed
        #expect(status.menuTitle == "Vimac · 监听异常")
        #expect(!status.headline.contains("VISUAL"))
    }
}
