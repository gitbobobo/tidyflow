import Foundation

/// 用于 MessagePack 编解码的动态类型包装器
/// 支持将 [String: Any] 字典编码为 MessagePack 格式
enum AnyCodable: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case dictionary([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            // 字典和数组必须在 double 之前检测，否则 MessagePack 的 fixmap/fixarray 字节会被误解为 double
            self = .dictionary(dictionary)
        } else if let array = try? container.decode([AnyCodable].self) {
            self = .array(array)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable 无法解码此值"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .dictionary(let value):
            try container.encode(value)
        }
    }

    /// 从 Any 类型创建 AnyCodable
    static func from(_ value: Any) -> AnyCodable {
        switch value {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map { from($0) })
        case let dict as [String: Any]:
            return .dictionary(dict.mapValues { from($0) })
        default:
            // 尝试转换为字符串
            return .string(String(describing: value))
        }
    }

    /// 转换为 Any 类型
    var toAny: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let value):
            return value.map { $0.toAny }
        case .dictionary(let value):
            return value.mapValues { $0.toAny }
        }
    }

    /// 转换为 [String: Any] 字典（仅当 self 是 dictionary 时有效）
    var toDictionary: [String: Any]? {
        guard case .dictionary(let dict) = self else { return nil }
        return dict.mapValues { $0.toAny }
    }
}
