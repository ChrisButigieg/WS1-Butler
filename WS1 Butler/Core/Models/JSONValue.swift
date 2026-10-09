import Foundation

/// A lossless, type-safe representation of arbitrary JSON.
///
/// UEM assignment rules contain dozens of fields (phased deployments, tunnels,
/// Windows-only options, …). Round-tripping them through a strongly typed model
/// would silently drop anything we did not model, and a PUT would then erase
/// those settings on the server. Keeping the raw JSON and only editing the
/// specific keys we care about avoids that class of bug entirely.
nonisolated enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Convenience accessors

    subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let dict) = self else { return nil }
            return dict[key]
        }
        set {
            guard case .object(var dict) = self else { return }
            dict[key] = newValue
            self = .object(dict)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .double(let value): return Int(exactly: value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value): return Bool(value.lowercased())
        case .int(let value): return value != 0
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// Returns a copy with every `id` / `uuid` key removed at any depth.
    /// Used when copying an assignment rule from one application version to another,
    /// so the server creates fresh records instead of colliding with the old ones.
    func removingIdentifiers() -> JSONValue {
        switch self {
        case .object(let dict):
            var copy: [String: JSONValue] = [:]
            for (key, value) in dict where key != "id" && key != "uuid" {
                copy[key] = value.removingIdentifiers()
            }
            return .object(copy)
        case .array(let items):
            return .array(items.map { $0.removingIdentifiers() })
        default:
            return self
        }
    }
}
