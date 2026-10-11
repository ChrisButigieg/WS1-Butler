import Foundation

/// Delivery choices accepted by the UEM v2 assignment-rules API.
nonisolated enum AppDeliveryMethod: String, CaseIterable, Hashable, Sendable, Identifiable {
    case automatic = "AUTO"
    case onDemand = "ON_DEMAND"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .onDemand: "On Demand"
        }
    }
}

/// Value types accepted by UEM for managed application configuration entries.
nonisolated enum AppConfigurationType: String, CaseIterable, Hashable, Sendable, Identifiable {
    case string = "STRING"
    case integer = "INTEGER"
    case boolean = "BOOLEAN"
    case date = "DATE"
    case array = "ARRAY"
    case choice = "CHOICE"
    case multiSelect = "MULTI_SELECT"
    case hidden = "HIDDEN"
    case stringArray = "STRING_ARRAY"
    case integerArray = "INTEGER_ARRAY"
    case bundle = "BUNDLE"
    case bundleArray = "BUNDLE_ARRAY"

    var id: String { rawValue }

    var title: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Types that UEM accepts as an individual key/value configuration entry.
    /// Complex types require nested configuration structures, which the review editor does not author.
    var supportsSimpleKeyValue: Bool {
        switch self {
        case .string, .integer, .boolean, .date:
            true
        case .array, .choice, .multiSelect, .hidden, .stringArray, .integerArray, .bundle, .bundleArray:
            false
        }
    }

    static var simpleKeyValueCases: [Self] {
        allCases.filter(\.supportsSimpleKeyValue)
    }
}

/// A locally authored managed app configuration entry. The identifier is UI-only and is never sent to UEM.
nonisolated struct NewAppConfiguration: Hashable, Sendable, Identifiable {
    let id: UUID
    var key: String
    var value: String
    var type: AppConfigurationType

    init(id: UUID = UUID(), key: String = "", value: String = "", type: AppConfigurationType = .string) {
        self.id = id
        self.key = key
        self.value = value
        self.type = type
    }
}

/// Restriction defaults for a newly authored assignment. Field names map directly to UEM's v2 API.
nonisolated struct NewAssignmentRestrictions: Hashable, Sendable {
    var removeOnUnenroll = true
    var preventRemoval = false
    var preventApplicationBackup = true
    var makeAppMDMManaged = true
}

/// A new assignment authored during review. It remains local until the operator approves publishing.
nonisolated struct NewDistribution: Hashable, Sendable {
    var assignmentName: String
    var assignmentDescription: String
    var deploymentBeginning: Date
    var deliveryMethod: AppDeliveryMethod
    var smartGroupUUIDs: [String]
    var restrictions: NewAssignmentRestrictions
    var sendConfiguration: Bool
    var configuration: [NewAppConfiguration]

    init(
        assignmentName: String,
        assignmentDescription: String = "",
        deploymentBeginning: Date = .now,
        deliveryMethod: AppDeliveryMethod = .automatic,
        smartGroupUUIDs: [String] = [],
        restrictions: NewAssignmentRestrictions = .init(),
        sendConfiguration: Bool = false,
        configuration: [NewAppConfiguration] = []
    ) {
        self.assignmentName = assignmentName
        self.assignmentDescription = assignmentDescription
        self.deploymentBeginning = deploymentBeginning
        self.deliveryMethod = deliveryMethod
        self.smartGroupUUIDs = smartGroupUUIDs
        self.restrictions = restrictions
        self.sendConfiguration = sendConfiguration
        self.configuration = configuration
    }

    func validate(usedSmartGroupUUIDs: Set<String>) throws {
        guard !assignmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NewDistributionValidationError.missingAssignmentName
        }

        let selectedGroups = normalizedSmartGroupUUIDs
        guard !selectedGroups.isEmpty else { throw NewDistributionValidationError.missingSmartGroups }
        guard Set(selectedGroups).count == selectedGroups.count else {
            throw NewDistributionValidationError.duplicateSmartGroups
        }
        guard usedSmartGroupUUIDs.isDisjoint(with: selectedGroups) else {
            throw NewDistributionValidationError.unavailableSmartGroup
        }

        guard sendConfiguration else { return }
        guard !configuration.isEmpty else { throw NewDistributionValidationError.missingConfiguration }

        let keys = configuration.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard keys.allSatisfy({ !$0.isEmpty }) else {
            throw NewDistributionValidationError.missingConfigurationKey
        }
        guard Set(keys.map { $0.lowercased() }).count == keys.count else {
            throw NewDistributionValidationError.duplicateConfigurationKeys
        }
        for entry in configuration {
            guard entry.type.supportsSimpleKeyValue else {
                throw NewDistributionValidationError.unsupportedConfigurationType(entry.type)
            }
            guard Self.hasValidValue(entry) else {
                throw NewDistributionValidationError.invalidConfigurationValue(key: entry.key, type: entry.type)
            }
        }
    }

    var normalizedSmartGroupUUIDs: [String] {
        smartGroupUUIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func hasValidValue(_ entry: NewAppConfiguration) -> Bool {
        let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch entry.type {
        case .string:
            return true
        case .boolean:
            return ["true", "false"].contains(value.lowercased())
        case .integer:
            return Int(value) != nil
        case .date:
            return ISO8601DateFormatter().date(from: value) != nil || {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: value) != nil
            }()
        case .array, .choice, .multiSelect, .hidden, .stringArray, .integerArray, .bundle, .bundleArray:
            return false
        }
    }
}

nonisolated enum NewDistributionValidationError: LocalizedError, Equatable, Sendable {
    case missingAssignmentName
    case missingSmartGroups
    case duplicateSmartGroups
    case unavailableSmartGroup
    case missingConfiguration
    case missingConfigurationKey
    case duplicateConfigurationKeys
    case unsupportedConfigurationType(AppConfigurationType)
    case invalidConfigurationValue(key: String, type: AppConfigurationType)

    var errorDescription: String? {
        switch self {
        case .missingAssignmentName: "Enter an assignment name."
        case .missingSmartGroups: "Select at least one Smart Group."
        case .duplicateSmartGroups: "A Smart Group can be selected only once."
        case .unavailableSmartGroup: "A selected Smart Group is already assigned or excluded by this app."
        case .missingConfiguration: "Add a configuration key/value pair or turn off Send Configuration."
        case .missingConfigurationKey: "Every configuration row needs a key."
        case .duplicateConfigurationKeys: "Configuration keys must be unique."
        case .unsupportedConfigurationType(let type): "\(type.title) requires nested configuration and is not supported by the key/value editor."
        case .invalidConfigurationValue(let key, let type): "Enter a valid \(type.title.lowercased()) value for \(key)."
        }
    }
}

/// Imports the scalar key/value entries in an Apple XML property list for managed app configuration.
/// Arrays and nested dictionaries are rejected rather than being guessed into an incompatible UEM payload.
nonisolated enum AppConfigurationXMLImporter {
    static func configurations(from data: Data) throws -> [NewAppConfiguration] {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw AppConfigurationXMLImportError.invalidPropertyList
        }

        guard format == .xml else { throw AppConfigurationXMLImportError.notXML }
        guard let dictionary = propertyList as? [String: Any] else {
            throw AppConfigurationXMLImportError.invalidRoot
        }

        return try dictionary.keys.sorted().map { key in
            guard let value = dictionary[key] else { throw AppConfigurationXMLImportError.invalidRoot }
            return try configuration(key: key, value: value)
        }
    }

    private static func configuration(key: String, value: Any) throws -> NewAppConfiguration {
        switch value {
        case let value as String:
            return NewAppConfiguration(key: key, value: value, type: .string)
        case let value as Date:
            return NewAppConfiguration(key: key, value: ISO8601DateFormatter().string(from: value), type: .date)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return NewAppConfiguration(key: key, value: value.boolValue ? "true" : "false", type: .boolean)
            }
            if value.doubleValue.rounded() == value.doubleValue {
                return NewAppConfiguration(key: key, value: value.stringValue, type: .integer)
            }
            return NewAppConfiguration(key: key, value: value.stringValue, type: .string)
        case is [Any], is [String: Any]:
            throw AppConfigurationXMLImportError.unsupportedValue(key)
        default:
            throw AppConfigurationXMLImportError.unsupportedValue(key)
        }
    }
}

nonisolated enum AppConfigurationXMLImportError: LocalizedError, Equatable, Sendable {
    case invalidPropertyList
    case notXML
    case invalidRoot
    case unsupportedValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidPropertyList: "The selected file is not a valid property-list configuration."
        case .notXML: "Select an XML property-list configuration file."
        case .invalidRoot: "The XML configuration must contain a top-level dictionary of keys and values."
        case .unsupportedValue(let key): "The value for \(key) is nested or an array. Add that configuration manually."
        }
    }
}

/// One managed app configuration key/value pair inside an assignment.
nonisolated struct AppConfigEntry: Hashable, Sendable, Identifiable {
    /// Key path. Nested bundle entries are flattened as `parent/child`.
    var key: String
    var value: String
    /// UEM configuration type (STRING, INTEGER, BOOLEAN, …).
    var type: String
    /// Only top-level entries can be edited; nested bundle entries are shown read-only.
    var isEditable: Bool

    var id: String { key }
}

/// Read-only projection of one assignment group in a v2 assignment rule.
nonisolated struct AssignmentSummary: Hashable, Sendable, Identifiable {
    let index: Int
    let name: String
    let description: String
    let priority: Int
    let smartGroupUUIDs: [String]
    let deliveryMethod: String
    let effectiveDate: String?
    let restrictions: AssignmentRestrictionSummary
    let configuration: [AppConfigEntry]

    var id: Int { index }

    /// Identity used to match assignment groups between two app versions.
    var matchKey: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "#priority-\(priority)" : trimmed
    }
}

/// Read-only projection of restrictions on an existing assignment.
nonisolated struct AssignmentRestrictionSummary: Hashable, Sendable {
    let removeOnUnenroll: Bool?
    let preventRemoval: Bool?
    let preventApplicationBackup: Bool?
    let makeAppMDMManaged: Bool?

    var hasValues: Bool {
        removeOnUnenroll != nil || preventRemoval != nil || preventApplicationBackup != nil || makeAppMDMManaged != nil
    }
}

/// Wraps the raw JSON returned by `GET /api/mam/apps/{uuid}/assignment-rules` (v2).
///
/// All reads go through typed accessors and all edits mutate the raw JSON in place, so
/// fields this app does not understand are preserved byte-for-byte on the next PUT.
nonisolated struct AssignmentRuleDocument: Sendable, Hashable {
    var raw: JSONValue

    static let empty = AssignmentRuleDocument(raw: .object([
        "assignments": .array([]),
        "excluded_smart_groups": .array([])
    ]))

    var isEmpty: Bool { assignments.isEmpty }

    var excludedSmartGroups: [String] {
        (raw["excluded_smart_groups"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    var assignments: [AssignmentSummary] {
        let items = raw["assignments"]?.arrayValue ?? []
        return items.enumerated().map { index, item in
            let distribution = item["distribution"] ?? .null
            let configs = item["application_configuration"]?.arrayValue
                ?? distribution["application_configuration"]?.arrayValue
                ?? []
            let restriction = item["restriction"] ?? .null
            return AssignmentSummary(
                index: index,
                name: distribution["name"]?.stringValue ?? "",
                description: distribution["description"]?.stringValue ?? "",
                priority: item["priority"]?.intValue ?? index,
                smartGroupUUIDs: (distribution["smart_groups"]?.arrayValue ?? []).compactMap(\.stringValue),
                deliveryMethod: distribution["app_delivery_method"]?.stringValue ?? "",
                effectiveDate: distribution["effective_date"]?.stringValue,
                restrictions: AssignmentRestrictionSummary(
                    removeOnUnenroll: restriction["remove_on_unenroll"]?.boolValue,
                    preventRemoval: restriction["prevent_removal"]?.boolValue,
                    preventApplicationBackup: restriction["prevent_application_backup"]?.boolValue,
                    makeAppMDMManaged: restriction["make_app_mdm_managed"]?.boolValue
                ),
                configuration: Self.flatten(configs, prefix: nil)
            )
        }
    }

    private static func flatten(_ configs: [JSONValue], prefix: String?) -> [AppConfigEntry] {
        var result: [AppConfigEntry] = []
        for config in configs {
            guard let key = config["key"]?.stringValue else { continue }
            let path = prefix.map { "\($0)/\(key)" } ?? key
            result.append(AppConfigEntry(
                key: path,
                value: config["value"]?.stringValue ?? "",
                type: config["type"]?.stringValue ?? "STRING",
                isEditable: prefix == nil
            ))
            if let nested = config["nested_configurations"]?.arrayValue, !nested.isEmpty {
                result += flatten(nested, prefix: path)
            }
        }
        return result
    }

    /// Updates the value of a top-level app configuration key in a given assignment.
    /// - Returns: `true` when the key existed and was updated.
    @discardableResult
    mutating func setConfigurationValue(_ value: String, forKey key: String, assignmentIndex: Int) -> Bool {
        guard var items = raw["assignments"]?.arrayValue, items.indices.contains(assignmentIndex) else { return false }

        if var configs = items[assignmentIndex]["application_configuration"]?.arrayValue,
           let configIndex = configs.firstIndex(where: { $0["key"]?.stringValue == key }) {
            configs[configIndex]["value"] = .string(value)
            items[assignmentIndex]["application_configuration"] = .array(configs)
            raw["assignments"] = .array(items)
            return true
        }

        guard var distribution = items[assignmentIndex]["distribution"],
              var configs = distribution["application_configuration"]?.arrayValue,
              let configIndex = configs.firstIndex(where: { $0["key"]?.stringValue == key })
        else { return false }

        configs[configIndex]["value"] = .string(value)
        distribution["application_configuration"] = .array(configs)
        items[assignmentIndex]["distribution"] = distribution
        raw["assignments"] = .array(items)
        return true
    }

    /// Appends a new v2 assignment. The payload is kept local until the review gate approves publishing.
    mutating func appendDistribution(_ distribution: NewDistribution) throws {
        try distribution.validate(usedSmartGroupUUIDs: unavailableSmartGroupUUIDs)

        var items = raw["assignments"]?.arrayValue ?? []
        let nextPriority = (items.compactMap { $0["priority"]?.intValue }.max() ?? -1) + 1
        let description = distribution.assignmentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var distributionJSON: [String: JSONValue] = [
            "name": .string(distribution.assignmentName.trimmingCharacters(in: .whitespacesAndNewlines)),
            "smart_groups": .array(distribution.normalizedSmartGroupUUIDs.map(JSONValue.string)),
            "app_delivery_method": .string(distribution.deliveryMethod.rawValue),
            "effective_date": .string(Self.effectiveDateString(distribution.deploymentBeginning))
        ]
        if !description.isEmpty { distributionJSON["description"] = .string(description) }

        var assignment: [String: JSONValue] = [
            "priority": .int(Int64(nextPriority)),
            "distribution": .object(distributionJSON),
            "restriction": .object([
                "remove_on_unenroll": .bool(distribution.restrictions.removeOnUnenroll),
                "prevent_removal": .bool(distribution.restrictions.preventRemoval),
                "prevent_application_backup": .bool(distribution.restrictions.preventApplicationBackup),
                "make_app_mdm_managed": .bool(distribution.restrictions.makeAppMDMManaged)
            ])
        ]
        if distribution.sendConfiguration {
            assignment["application_configuration"] = .array(distribution.configuration.map(Self.jsonConfiguration))
        }

        items.append(.object(assignment))
        raw["assignments"] = .array(items)
    }

    /// Smart Groups already used by an assignment or exclusion. UEM rejects duplicates in a new assignment.
    var unavailableSmartGroupUUIDs: Set<String> {
        let assignmentGroups = assignments.flatMap(\.smartGroupUUIDs).map { $0.lowercased() }
        return Set(assignmentGroups + excludedSmartGroups.map { $0.lowercased() })
    }

    private static func jsonConfiguration(_ configuration: NewAppConfiguration) -> JSONValue {
        let value: String
        switch configuration.type {
        case .boolean:
            value = configuration.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .integer, .date:
            value = configuration.value.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            value = configuration.value
        }
        return .object([
            "key": .string(configuration.key.trimmingCharacters(in: .whitespacesAndNewlines)),
            "value": .string(value),
            "type": .string(configuration.type.rawValue)
        ])
    }

    /// Formats the operator-selected deployment time in the local RFC 3339 offset expected by
    /// the UEM assignment-rules API (for example, `2026-10-15T09:20:00.000-04:00`).
    /// `ISO8601DateFormatter` defaults to GMT, which would turn a local deployment time into
    /// a Zulu timestamp before UEM displays it in the console.
    static func effectiveDateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// A copy suitable for applying to a *different* application (identifiers stripped).
    func preparedForTransfer() -> AssignmentRuleDocument {
        AssignmentRuleDocument(raw: raw.removingIdentifiers())
    }
}

// MARK: - Comparison

nonisolated struct AssignmentDiscrepancy: Hashable, Sendable, Identifiable {
    nonisolated enum Kind: String, Sendable {
        case missingAssignment = "MISSING ASSIGNMENT"
        case unexpectedAssignment = "UNEXPECTED ASSIGNMENT"
        case smartGroups = "SMART GROUPS"
        case deliveryMethod = "DELIVERY METHOD"
        case configuration = "APP CONFIG"
        case exclusions = "EXCLUSIONS"
    }

    let kind: Kind
    let assignmentName: String
    let detail: String

    var id: String { "\(kind.rawValue)|\(assignmentName)|\(detail)" }
}

/// Compares the assignment rule of the previous app version (expected) with the
/// rule UEM carried over to the new version (actual).
nonisolated enum AssignmentComparator {
    static func compare(expected: AssignmentRuleDocument, actual: AssignmentRuleDocument) -> [AssignmentDiscrepancy] {
        var issues: [AssignmentDiscrepancy] = []
        let expectedGroups = expected.assignments
        let actualByKey = Dictionary(actual.assignments.map { ($0.matchKey, $0) }, uniquingKeysWith: { first, _ in first })
        let expectedKeys = Set(expectedGroups.map(\.matchKey))

        for exp in expectedGroups {
            let label = exp.name.isEmpty ? "Priority \(exp.priority)" : exp.name
            guard let act = actualByKey[exp.matchKey] else {
                issues.append(.init(kind: .missingAssignment, assignmentName: label,
                                    detail: "Assignment group is not present on the new version."))
                continue
            }
            if Set(exp.smartGroupUUIDs) != Set(act.smartGroupUUIDs) {
                let missing = Set(exp.smartGroupUUIDs).subtracting(act.smartGroupUUIDs).count
                let extra = Set(act.smartGroupUUIDs).subtracting(exp.smartGroupUUIDs).count
                issues.append(.init(kind: .smartGroups, assignmentName: label,
                                    detail: "\(missing) smart group(s) missing, \(extra) unexpected."))
            }
            if exp.deliveryMethod.caseInsensitiveCompare(act.deliveryMethod) != .orderedSame {
                issues.append(.init(kind: .deliveryMethod, assignmentName: label,
                                    detail: "Expected \(display(exp.deliveryMethod)), found \(display(act.deliveryMethod))."))
            }
            issues += compareConfiguration(expected: exp.configuration, actual: act.configuration, label: label)
        }

        for act in actual.assignments where !expectedKeys.contains(act.matchKey) {
            let label = act.name.isEmpty ? "Priority \(act.priority)" : act.name
            issues.append(.init(kind: .unexpectedAssignment, assignmentName: label,
                                detail: "Assignment group exists only on the new version."))
        }

        if Set(expected.excludedSmartGroups) != Set(actual.excludedSmartGroups) {
            issues.append(.init(kind: .exclusions, assignmentName: "All",
                                detail: "Excluded smart groups differ from the previous version."))
        }
        return issues
    }

    private static func compareConfiguration(expected: [AppConfigEntry], actual: [AppConfigEntry], label: String) -> [AssignmentDiscrepancy] {
        var issues: [AssignmentDiscrepancy] = []
        let actualMap = Dictionary(actual.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let expectedKeys = Set(expected.map(\.key))
        for entry in expected {
            guard let value = actualMap[entry.key] else {
                issues.append(.init(kind: .configuration, assignmentName: label, detail: "Key '\(entry.key)' is missing."))
                continue
            }
            if value != entry.value {
                issues.append(.init(kind: .configuration, assignmentName: label,
                                    detail: "Key '\(entry.key)' changed from '\(entry.value)' to '\(value)'."))
            }
        }
        for entry in actual where !expectedKeys.contains(entry.key) {
            issues.append(.init(kind: .configuration, assignmentName: label, detail: "Key '\(entry.key)' was added."))
        }
        return issues
    }

    private static func display(_ method: String) -> String {
        method.isEmpty ? "none" : method
    }
}
