import Foundation

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
    let priority: Int
    let smartGroupUUIDs: [String]
    let deliveryMethod: String
    let configuration: [AppConfigEntry]

    var id: Int { index }

    /// Identity used to match assignment groups between two app versions.
    var matchKey: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "#priority-\(priority)" : trimmed
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
            let configs = distribution["application_configuration"]?.arrayValue ?? []
            return AssignmentSummary(
                index: index,
                name: distribution["name"]?.stringValue ?? "",
                priority: item["priority"]?.intValue ?? index,
                smartGroupUUIDs: (distribution["smart_groups"]?.arrayValue ?? []).compactMap(\.stringValue),
                deliveryMethod: distribution["app_delivery_method"]?.stringValue ?? "",
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
        guard var items = raw["assignments"]?.arrayValue,
              items.indices.contains(assignmentIndex),
              var distribution = items[assignmentIndex]["distribution"],
              var configs = distribution["application_configuration"]?.arrayValue,
              let configIndex = configs.firstIndex(where: { $0["key"]?.stringValue == key })
        else { return false }

        configs[configIndex]["value"] = .string(value)
        distribution["application_configuration"] = .array(configs)
        items[assignmentIndex]["distribution"] = distribution
        raw["assignments"] = .array(items)
        return true
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
