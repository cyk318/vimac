import Foundation

public enum ConfigError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct CursorStyle: Codable {
    public var color = "#FFFFFF"
    public var style = "block"
    public var opacity = 0.55
    public var width: Dimension = .auto
    public var height: Dimension = .auto
    public var borderColor = "#777777"
    public init() {}
}

public enum Dimension: Codable {
    case auto
    case points(Double)
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == "auto" { self = .auto }
        else {
            let value = try container.decode(Double.self)
            guard value.isFinite && value > 0 && value <= 200 else {
                throw ConfigError.invalid("cursor 宽高必须是 auto 或 0～200 之间的正数")
            }
            self = .points(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .auto: try container.encode("auto"); case .points(let value): try container.encode(value) }
    }
    public func resolve(_ automatic: Double) -> Double {
        switch self { case .auto: return automatic; case .points(let value): return value }
    }
}

public struct Theme: Codable {
    public var mode = "system"
    public var accentColor = "#66CCFF"
    public init() {}
}

public struct Configuration: Codable {
    public var toggleKey = "ctrl+option+v"
    public var keyMapping: [String: [String: Command]] = [:]
    public var cursor = CursorStyle()
    public var theme = Theme()
    public init() {}

    public static let normalKeys: [String: Command] = [
        "h": .moveLeft, "j": .moveDown, "k": .moveUp, "l": .moveRight,
        "w": .wordForward, "b": .wordBackward, "e": .wordEnd,
        "0": .lineStart, "$": .lineEnd, "x": .deleteCharacter,
        "dd": .deleteLine, "yy": .yankLine, "p": .paste, "u": .undo,
        "i": .insert, "v": .visual, "Esc": .normal
    ]
    public static let visualKeys: [String: Command] = normalKeys.filter { $0.value.isMotion }
        .merging(["v": .visual, "Esc": .normal, "y": .yank, "d": .delete, "c": .change]) { _, new in new }

    public func mappings(for mode: Mode) -> [String: Command] {
        let defaults = mode == .visual ? Self.visualKeys : Self.normalKeys
        return defaults.merging(keyMapping[mode.rawValue] ?? [:]) { _, new in new }
    }

    /// 先与默认值按字段合并，再用真实 Codable 解码，允许用户仅填写想改的字段。
    public static func decode(_ data: Data) throws -> Configuration {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let defaults = try JSONSerialization.jsonObject(with: encoder.encode(Configuration())) as! [String: Any]
        guard let supplied = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalid("配置必须是 JSON 对象")
        }
        func merge(_ base: [String: Any], _ patch: [String: Any], path: String) throws -> [String: Any] {
            var result = base
            for (key, value) in patch {
                if path != "key_mapping" && !path.hasPrefix("key_mapping.") && base[key] == nil {
                    throw ConfigError.invalid("未知配置字段：\(path.isEmpty ? key : path + "." + key)")
                }
                if let old = base[key] as? [String: Any], let new = value as? [String: Any] {
                    result[key] = try merge(old, new, path: path.isEmpty ? key : path + "." + key)
                } else { result[key] = value }
            }
            return result
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(Configuration.self, from: JSONSerialization.data(withJSONObject: merge(defaults, supplied, path: "")))
        try config.validate()
        return config
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func validate() throws {
        _ = try Shortcut(toggleKey)
        for color in [cursor.color, cursor.borderColor, theme.accentColor] {
            guard color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw ConfigError.invalid("颜色必须使用 #RRGGBB：\(color)")
            }
        }
        guard ["block", "outline", "bar"].contains(cursor.style), (0...1).contains(cursor.opacity) else {
            throw ConfigError.invalid("cursor.style 或 cursor.opacity 无效")
        }
        guard ["system", "light", "dark"].contains(theme.mode) else { throw ConfigError.invalid("theme.mode 无效") }
        for mode in keyMapping.keys where mode != "normal" && mode != "visual" {
            throw ConfigError.invalid("key_mapping 不支持模式：\(mode)")
        }
        for mode in [Mode.normal, .visual] {
            let map = mappings(for: mode)
            let allowed = Set((mode == .normal ? Self.normalKeys : Self.visualKeys).values)
            for (key, command) in map {
                guard allowed.contains(command), key == "Esc" || (1...2).contains(key.count) && key.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
                    throw ConfigError.invalid("key_mapping.\(mode.rawValue).\(key) 无效")
                }
                if key != "Esc" && map.keys.contains(where: { $0 != key && $0.hasPrefix(key) }) {
                    throw ConfigError.invalid("键位前缀冲突：\(key)")
                }
            }
            guard map["Esc"] == .normal else { throw ConfigError.invalid("Esc 必须保留为 normal") }
        }
    }
}

public struct Shortcut {
    public let key: String
    public let modifiers: Set<String>
    public init(_ value: String) throws {
        let parts = value.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, last.count == 1, last.first!.isASCII,
              last.first!.isLetter || last.first!.isNumber else { throw ConfigError.invalid("toggle_key 末尾须为字母或数字") }
        let modifiers = Set(parts.dropLast())
        guard !modifiers.isEmpty, modifiers.count == parts.count - 1,
              modifiers.isSubset(of: ["ctrl", "option", "cmd", "shift"]),
              !modifiers.isDisjoint(with: ["ctrl", "option", "cmd"]),
              !(modifiers == ["cmd"] && ["q", "w", "c", "v", "x", "z", "a", "s"].contains(last)) else {
            throw ConfigError.invalid("toggle_key 修饰键无效或与系统编辑快捷键冲突")
        }
        key = last; self.modifiers = modifiers
    }
}

public struct KeyParser {
    private var pending = ""
    private var started: TimeInterval = 0
    public init() {}
    public mutating func reset() { pending = "" }
    public mutating func command(for key: String, time: TimeInterval, repeated: Bool, mappings: [String: Command]) -> Command? {
        if time - started > 0.8 || key == "Esc" { reset() }
        if repeated { return mappings[key].flatMap { $0.isMotion ? $0 : nil } }
        let sequence = pending + key
        reset()
        if let command = mappings[sequence] { return command }
        if mappings.keys.contains(where: { $0.hasPrefix(sequence) }) { pending = sequence; started = time }
        return nil
    }
}
