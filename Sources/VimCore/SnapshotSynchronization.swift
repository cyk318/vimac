import Foundation

public enum SnapshotSynchronization {
    /// Normal 不持有跨命令选区，可用宿主最新快照重新定位；Visual 的锚点不能猜测迁移。
    public static func mustEndSession(mode: Mode, previous: Snapshot?, current: Snapshot) -> Bool {
        mode == .visual && previous.map { $0 != current } == true
    }
}
