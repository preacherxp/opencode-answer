import Foundation

/// A form value as OpenCode encodes it: string, number, boolean, or string array.
enum FormValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) {
            switch v {
            case "Infinity": self = .number(.infinity)
            case "-Infinity": self = .number(-.infinity)
            case "NaN": self = .number(.nan)
            default: self = .string(v)
            }
        }
        else if let v = try? c.decode([String].self) { self = .array(v) }
        else { throw DecodingError.typeMismatch(FormValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported form value")) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }

    var number: Double? {
        if case .number(let v) = self, v.isFinite { return v }
        return nil
    }

    func matches(_ other: FormValue) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.array(let a), .string(let b)): return a.contains(b)
        case (.array(let a), .array(let b)): return Set(a) == Set(b)
        default: return false
        }
    }
}

struct FormOption: Decodable, Hashable {
    let value: String
    let label: String
    let description: String?
}

struct FormWhen: Decodable, Hashable {
    let key: String
    let op: String
    let value: FormValue
}

struct FormField: Decodable, Identifiable, Hashable {
    let key: String
    let type: String
    let title: String?
    let description: String?
    let required: Bool?
    let hidden: Bool?
    let when: [FormWhen]?
    let options: [FormOption]?
    let custom: Bool?
    let placeholder: String?
    let format: String?
    let minItems: Int?
    let maxItems: Int?
    let minimum: FormValue?
    let maximum: FormValue?
    let url: String?
    let defaultValue: FormValue?

    var id: String { key }
    var isRequired: Bool { required ?? false }
    var allowsCustom: Bool { custom ?? false }

    enum CodingKeys: String, CodingKey {
        case key, type, title, description, required, hidden, when, options, custom
        case placeholder, format, minItems, maxItems, minimum, maximum, url
        case defaultValue = "default"
    }
}

struct FormInfo: Decodable, Identifiable, Hashable {
    let id: String
    let sessionID: String
    let title: String
    let fields: [FormField]
}

/// A pending form plus the context needed to show where it came from.
struct PendingQuestion: Identifiable, Hashable {
    let form: FormInfo
    var directory: String?
    var sessionTitle: String?
    let receivedAt: Date

    var id: String { form.id }

    var projectName: String {
        guard let directory else { return "OpenCode" }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}
