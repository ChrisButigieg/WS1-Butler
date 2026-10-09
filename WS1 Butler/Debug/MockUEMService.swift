#if DEBUG
import Foundation

/// In-process fake UEM server used by unit tests, UI tests, and demo mode.
/// Records every call so tests can assert on the exact sequence of API operations.
final class MockUEMService: UEMService {
    var calls: [String] = []
    var latency: Duration = .zero

    var organizationGroup = UEMOrganizationGroup(name: "AFRC Mobility", groupID: "AFRC", entityID: .init(value: 570), uuid: "og-uuid")
    var existingApps: [UEMApplication] = []
    var rules: [String: AssignmentRuleDocument] = [:]
    var smartGroups: [String: String] = [:]
    var newAppTemplate = UEMApplication(entityID: .init(value: 2002), uuid: "new-app-uuid")
    /// Rule UEM "carries over" to the newly created version. `nil` copies the previous rule.
    var carriedRuleOverride: AssignmentRuleDocument?

    var failAuthentication: Error?
    var failBeginInstall: Error?
    var failRetire: Error?
    var failUpload: Error?

    private(set) var beginInstallRequests: [BeginInstallRequest] = []
    private(set) var publishedRules: [String: AssignmentRuleDocument] = [:]
    private(set) var retiredAppIDs: [Int] = []
    private(set) var deletedBlobIDs: [Int] = []

    private func pause() async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
    }

    func testConnection() async throws -> UEMOrganizationGroup {
        calls.append("testConnection")
        try await pause()
        if let failAuthentication { throw failAuthentication }
        return organizationGroup
    }

    func searchOrganizationGroups(groupID: String) async throws -> [UEMOrganizationGroup] {
        calls.append("searchOrganizationGroups")
        return [organizationGroup]
    }

    func findInternalApps(bundleID: String) async throws -> [UEMApplication] {
        calls.append("findInternalApps")
        try await pause()
        return existingApps.filter { $0.bundleID == bundleID }
    }

    func assignmentRule(appUUID: String) async throws -> AssignmentRuleDocument {
        calls.append("assignmentRule:\(appUUID)")
        try await pause()
        if appUUID == newAppTemplate.uuid, rules[appUUID] == nil {
            if let carriedRuleOverride { return carriedRuleOverride }
            // Mimic CarryOverAssignments: the previous active version's rule.
            let previousUUID = existingApps.first(where: \.isActive)?.uuid ?? ""
            return rules[previousUUID] ?? .empty
        }
        return rules[appUUID] ?? .empty
    }

    func updateAssignmentRule(appUUID: String, rule: AssignmentRuleDocument) async throws {
        calls.append("updateAssignmentRule:\(appUUID)")
        try await pause()
        publishedRules[appUUID] = rule
        rules[appUUID] = rule
    }

    func smartGroupNames() async throws -> [String: String] {
        calls.append("smartGroupNames")
        return smartGroups
    }

    func uploadBlob(fileURL: URL, fileName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        calls.append("uploadBlob:\(fileName)")
        if let failUpload { throw failUpload }
        for step in 1...5 {
            try await pause()
            progress(Double(step) / 5)
        }
        return 777
    }

    func deleteBlob(id: Int) async throws {
        calls.append("deleteBlob:\(id)")
        deletedBlobIDs.append(id)
    }

    func beginInstall(_ request: BeginInstallRequest) async throws -> UEMApplication {
        calls.append("beginInstall")
        try await pause()
        beginInstallRequests.append(request)
        if let failBeginInstall { throw failBeginInstall }
        var app = newAppTemplate
        app.applicationName = request.applicationName
        app.status = "Active"
        return app
    }

    func retireApp(id: Int) async throws {
        calls.append("retireApp:\(id)")
        try await pause()
        if let failRetire { throw failRetire }
        retiredAppIDs.append(id)
    }

    // MARK: Fixtures

    static func sampleRule(configValue: String = "https://api.dev.example.mil") -> AssignmentRuleDocument {
        AssignmentRuleDocument(raw: .object([
            "id": .int(91),
            "uuid": .string("rule-uuid-old"),
            "assignments": .array([
                .object([
                    "priority": .int(0),
                    "distribution": .object([
                        "name": .string("Flight Line iPads"),
                        "smart_groups": .array([.string("sg-flightline")]),
                        "app_delivery_method": .string("AUTO"),
                        "keep_app_updated_automatically": .bool(true),
                        "application_configuration": .array([
                            .object(["key": .string("ServerURL"), "value": .string(configValue), "type": .string("STRING"), "id": .int(5)]),
                            .object(["key": .string("EnableLogging"), "value": .string("false"), "type": .string("BOOLEAN"), "id": .int(6)])
                        ])
                    ]),
                    "restriction": .object(["remove_on_unenroll": .bool(true), "managed_access": .bool(true)])
                ]),
                .object([
                    "priority": .int(1),
                    "distribution": .object([
                        "name": .string("Maintainers"),
                        "smart_groups": .array([.string("sg-maint"), .string("sg-qa")]),
                        "app_delivery_method": .string("ON_DEMAND"),
                        "application_configuration": .array([])
                    ])
                ])
            ]),
            "excluded_smart_groups": .array([])
        ]))
    }

    static func sampleExistingApp(bundleID: String, version: String = "1.0.0") -> UEMApplication {
        UEMApplication(applicationName: "Mission Planner", bundleID: bundleID, appVersion: version + ".0",
                       actualFileVersion: version, status: "Active", platform: 2, pushMode: "Auto",
                       locationGroupID: 570, assignedDeviceCount: 42, installedDeviceCount: 40,
                       supportedModels: .init(model: [.init(modelID: 2, modelName: "iPad")]),
                       entityID: .init(value: 1001), uuid: "old-app-uuid")
    }

    /// A ready-to-use mock with an existing app and a populated assignment rule.
    static func populated(bundleID: String) -> MockUEMService {
        let mock = MockUEMService()
        mock.existingApps = [sampleExistingApp(bundleID: bundleID)]
        mock.rules["old-app-uuid"] = sampleRule()
        mock.smartGroups = ["sg-flightline": "Flight Line iPads", "sg-maint": "Maintainers", "sg-qa": "QA Testers"]
        return mock
    }
}
#endif
