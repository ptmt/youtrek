import Foundation

enum IssueFieldKind: String, Codable, Hashable, Sendable {
    case enumeration = "enum"
    case state
    case version
    case build
    case ownedField
    case user
    case string
    case text
    case integer
    case float
    case date
    case dateTime
    case period
    case boolean
    case unknown

    static func from(kind: String?, valueType: String? = nil, fieldTypeID: String? = nil) -> IssueFieldKind {
        let candidates = [kind, valueType, fieldTypeID]
        for candidate in candidates {
            if let parsed = IssueFieldKind.parse(candidate) {
                return parsed
            }
        }
        return .unknown
    }

    private static func parse(_ value: String?) -> IssueFieldKind? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "enum", "enumeration", "enumfield", "enum-field": return .enumeration
        case "state": return .state
        case "version": return .version
        case "build": return .build
        case "ownedfield", "owned_field", "owned": return .ownedField
        case "user", "users": return .user
        case "string": return .string
        case "text": return .text
        case "integer", "int": return .integer
        case "float", "double", "decimal": return .float
        case "date": return .date
        case "datetime", "date-time", "date_time": return .dateTime
        case "period", "duration": return .period
        case "boolean", "bool": return .boolean
        default:
            return nil
        }
    }

    var usesOptions: Bool {
        switch self {
        case .enumeration, .state, .version, .build, .ownedField:
            return true
        case .user, .string, .text, .integer, .float, .date, .dateTime, .period, .boolean, .unknown:
            return false
        }
    }

    var usesPeople: Bool {
        self == .user
    }

    func issueCustomFieldTypeName(allowsMultiple: Bool) -> String {
        switch self {
        case .enumeration:
            return allowsMultiple ? "MultiEnumIssueCustomField" : "SingleEnumIssueCustomField"
        case .state:
            return allowsMultiple ? "MultiStateIssueCustomField" : "StateIssueCustomField"
        case .version:
            return allowsMultiple ? "MultiVersionIssueCustomField" : "SingleVersionIssueCustomField"
        case .build:
            return allowsMultiple ? "MultiBuildIssueCustomField" : "SingleBuildIssueCustomField"
        case .ownedField:
            return allowsMultiple ? "MultiOwnedIssueCustomField" : "SingleOwnedIssueCustomField"
        case .user:
            return allowsMultiple ? "MultiUserIssueCustomField" : "SingleUserIssueCustomField"
        case .text:
            return "TextIssueCustomField"
        case .string, .unknown:
            return "SimpleIssueCustomField"
        case .integer:
            return "SingleIntegerIssueCustomField"
        case .float:
            return "SingleFloatIssueCustomField"
        case .date:
            return "SingleDateIssueCustomField"
        case .dateTime:
            return "SingleDateTimeIssueCustomField"
        case .period:
            return "SinglePeriodIssueCustomField"
        case .boolean:
            return "SingleBooleanIssueCustomField"
        }
    }
}

struct IssueFieldOption: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let displayName: String
    let login: String?
    let avatarURL: URL?
    let ordinal: Int?

    init(
        id: String,
        name: String,
        displayName: String? = nil,
        login: String? = nil,
        avatarURL: URL? = nil,
        ordinal: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.login = login
        self.avatarURL = avatarURL
        self.ordinal = ordinal
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var stableID: String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? normalizedName : trimmed
    }
}

struct IssueField: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let localizedName: String?
    let kind: IssueFieldKind
    let isRequired: Bool
    let allowsMultiple: Bool
    let bundleID: String?
    var options: [IssueFieldOption]
    let ordinal: Int?

    var displayName: String {
        let preferred = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preferred.isEmpty { return preferred }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Field" : trimmed
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct IssueDraftField: Identifiable, Hashable, Sendable, Codable {
    var id: String { name }
    let name: String
    let kind: IssueFieldKind
    let allowsMultiple: Bool
    let value: IssueDraftFieldValue

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum IssueDraftFieldValue: Equatable, Hashable, Sendable, Codable {
    case none
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case date(Date)
    case option(IssueFieldOption)
    case options([IssueFieldOption])

    private enum CodingKeys: String, CodingKey {
        case type
        case string
        case integer
        case number
        case bool
        case date
        case option
        case options
    }

    private enum ValueType: String, Codable {
        case none
        case string
        case integer
        case number
        case bool
        case date
        case option
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .none:
            self = .none
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: .integer))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .number))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .date:
            self = .date(try container.decode(Date.self, forKey: .date))
        case .option:
            self = .option(try container.decode(IssueFieldOption.self, forKey: .option))
        case .options:
            self = .options(try container.decode([IssueFieldOption].self, forKey: .options))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(ValueType.none, forKey: .type)
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .string)
        case .integer(let value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .integer)
        case .number(let value):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .number)
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .bool)
        case .date(let value):
            try container.encode(ValueType.date, forKey: .type)
            try container.encode(value, forKey: .date)
        case .option(let value):
            try container.encode(ValueType.option, forKey: .type)
            try container.encode(value, forKey: .option)
        case .options(let value):
            try container.encode(ValueType.options, forKey: .type)
            try container.encode(value, forKey: .options)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .none:
            return true
        case .string(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .integer:
            return false
        case .number:
            return false
        case .bool:
            return false
        case .date:
            return false
        case .option:
            return false
        case .options(let values):
            return values.isEmpty
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .number(let value):
            return String(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value):
            return value
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .integer(let value):
            return Double(value)
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        default:
            return nil
        }
    }

    var dateValue: Date? {
        switch self {
        case .date(let value):
            return value
        default:
            return nil
        }
    }

    var optionValue: IssueFieldOption? {
        switch self {
        case .option(let value):
            return value
        case .options(let values):
            return values.first
        default:
            return nil
        }
    }

    var optionValues: [IssueFieldOption] {
        switch self {
        case .option(let value):
            return [value]
        case .options(let values):
            return values
        default:
            return []
        }
    }
}
