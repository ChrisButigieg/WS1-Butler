import Foundation
import Testing
@testable import WS1Butler

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Round-trips arbitrary JSON without losing fields or integer precision")
    func roundTrip() throws {
        let json = #"{"id":9007199254740993,"name":"x","ratio":1.5,"flag":false,"nothing":null,"list":[1,"two",{"deep":true}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["id"] == .int(9_007_199_254_740_993))
        #expect(value["ratio"] == .double(1.5))
        #expect(value["flag"] == .bool(false))
        #expect(value["nothing"] == .null)

        let reencoded = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        #expect(again == value)
    }

    @Test("removingIdentifiers strips id/uuid at every depth only")
    func stripsIdentifiers() {
        let value: JSONValue = .object([
            "id": .int(1), "uuid": .string("u"), "keep": .string("k"),
            "child": .array([.object(["id": .int(2), "smart_groups": .array([.string("sg-uuid")])])])
        ])
        let stripped = value.removingIdentifiers()
        #expect(stripped["id"] == nil)
        #expect(stripped["uuid"] == nil)
        #expect(stripped["keep"] == .string("k"))
        #expect(stripped["child"]?.arrayValue?.first?["id"] == nil)
        #expect(stripped["child"]?.arrayValue?.first?["smart_groups"] == .array([.string("sg-uuid")]))
    }
}

@Suite("Assignment rules")
struct AssignmentRuleTests {
    @Test("Projects assignments, smart groups, delivery method and config")
    func parsesSummary() {
        let rule = MockUEMService.sampleRule()
        let assignments = rule.assignments
        #expect(assignments.count == 2)
        #expect(assignments[0].name == "Flight Line iPads")
        #expect(assignments[0].smartGroupUUIDs == ["sg-flightline"])
        #expect(assignments[0].deliveryMethod == "AUTO")
        #expect(assignments[0].configuration.map(\.key) == ["ServerURL", "EnableLogging"])
        #expect(assignments[1].smartGroupUUIDs == ["sg-maint", "sg-qa"])
        #expect(assignments[1].configuration.isEmpty)
        #expect(!rule.isEmpty)
        #expect(AssignmentRuleDocument.empty.isEmpty)
    }

    @Test("Flattens nested bundle configuration as read-only")
    func nestedConfig() {
        let rule = AssignmentRuleDocument(raw: .object(["assignments": .array([
            .object(["distribution": .object(["name": .string("A"), "application_configuration": .array([
                .object(["key": .string("Parent"), "value": .string(""), "type": .string("BUNDLE"),
                         "nested_configurations": .array([.object(["key": .string("Child"), "value": .string("1"), "type": .string("INTEGER")])])])
            ])])])
        ])]))
        let config = rule.assignments[0].configuration
        #expect(config.map(\.key) == ["Parent", "Parent/Child"])
        #expect(config[0].isEditable)
        #expect(!config[1].isEditable)
    }

    @Test("Edits a config value in place and preserves unrelated fields")
    func editsConfig() throws {
        var rule = MockUEMService.sampleRule()
        let updated = rule.setConfigurationValue("https://prod.example.mil", forKey: "ServerURL", assignmentIndex: 0)
        #expect(updated)
        #expect(rule.assignments[0].configuration.first?.value == "https://prod.example.mil")
        // Unknown fields (restriction block, config id) survive the edit.
        let first = try #require(rule.raw["assignments"]?.arrayValue?.first)
        #expect(first["restriction"]?["managed_access"] == .bool(true))
        #expect(first["application_configuration"]?.arrayValue?.first?["id"] == .int(5))
        #expect(first["distribution"]?["keep_app_updated_automatically"] == .bool(true))
    }

    @Test("Editing an unknown key or out-of-range assignment is a no-op")
    func rejectsInvalidEdits() {
        var rule = MockUEMService.sampleRule()
        let before = rule
        let unknownKey = rule.setConfigurationValue("x", forKey: "Nope", assignmentIndex: 0)
        let outOfRange = rule.setConfigurationValue("x", forKey: "ServerURL", assignmentIndex: 9)
        let negative = rule.setConfigurationValue("x", forKey: "ServerURL", assignmentIndex: -1)
        #expect(!unknownKey)
        #expect(!outOfRange)
        #expect(!negative)
        #expect(rule == before)
    }

    @Test("Merged restore keeps the new rule's identifiers")
    func mergedRestore() {
        let carried = AssignmentRuleDocument(raw: .object(["id": .int(500), "uuid": .string("new-rule"), "assignments": .array([])]))
        let merged = DeploymentEngine.mergedForRestore(expected: MockUEMService.sampleRule(), carried: carried)
        #expect(merged.raw["id"] == .int(500))
        #expect(merged.raw["uuid"] == .string("new-rule"))
        #expect(merged.assignments.count == 2)
        #expect(merged.raw["assignments"]?.arrayValue?.first?["application_configuration"]?.arrayValue?.first?["id"] == nil)
    }

    @Test("New distributions use the documented defaults and v2 payload shape")
    func appendsNewDistribution() throws {
        let defaults = NewDistribution(assignmentName: "New app assignment")
        #expect(defaults.deliveryMethod == .automatic)
        #expect(defaults.restrictions.removeOnUnenroll)
        #expect(!defaults.restrictions.preventRemoval)
        #expect(defaults.restrictions.preventApplicationBackup)
        #expect(defaults.restrictions.makeAppMDMManaged)
        #expect(!defaults.sendConfiguration)
        #expect(abs(defaults.deploymentBeginning.timeIntervalSinceNow) < 5)

        var rule = AssignmentRuleDocument.empty
        try rule.appendDistribution(
            NewDistribution(
                assignmentName: "Test iPads",
                assignmentDescription: "New deployment",
                deploymentBeginning: Date(timeIntervalSince1970: 0),
                deliveryMethod: .onDemand,
                smartGroupUUIDs: ["SG-TEST"],
                sendConfiguration: true,
                configuration: [
                    NewAppConfiguration(key: "ServerURL", value: "https://config.example", type: .string),
                    NewAppConfiguration(key: "EnableLogging", value: "true", type: .boolean)
                ]
            )
        )

        let assignment = try #require(rule.raw["assignments"]?.arrayValue?.first)
        #expect(assignment["priority"] == .int(0))
        #expect(assignment["distribution"]?["name"] == .string("Test iPads"))
        #expect(assignment["distribution"]?["description"] == .string("New deployment"))
        #expect(assignment["distribution"]?["smart_groups"] == .array([.string("sg-test")]))
        #expect(assignment["distribution"]?["app_delivery_method"] == .string("ON_DEMAND"))
        #expect(assignment["distribution"]?["effective_date"]?.stringValue?.isEmpty == false)
        #expect(assignment["restriction"]?["remove_on_unenroll"] == .bool(true))
        #expect(assignment["restriction"]?["prevent_removal"] == .bool(false))
        #expect(assignment["restriction"]?["prevent_application_backup"] == .bool(true))
        #expect(assignment["restriction"]?["make_app_mdm_managed"] == .bool(true))
        #expect(assignment["application_configuration"]?.arrayValue?.map { $0["key"]?.stringValue } == ["ServerURL", "EnableLogging"])
        #expect(assignment["distribution"]?["application_configuration"] == nil)
    }

    @Test("New distributions preserve the operator's local deployment time and UTC offset")
    func effectiveDateUsesSelectedTimeZone() throws {
        let eastern = try #require(TimeZone(identifier: "America/New_York"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-15T13:20:00Z"))

        #expect(
            AssignmentRuleDocument.effectiveDateString(date, timeZone: eastern)
                == "2026-10-15T09:20:00.000-04:00"
        )
    }

    @Test("Distribution names auto-fill from the first Smart Group and delivery method")
    @MainActor
    func automaticDistributionName() {
        let draft = NewDistributionDraft()
        draft[smartGroupSelected: "sg-t6", displayName: "SG_DAF_EFB_T6_PERSONA"] = true
        #expect(draft.assignmentName == "DAF_EFB_T6_PERSONA_AUTO")

        draft.deliveryMethod = .onDemand
        #expect(draft.assignmentName == "DAF_EFB_T6_PERSONA_ONDEMAND")

        draft.isNameOverrideEnabled = true
        draft.assignmentName = "T6 Pilot"
        draft.deliveryMethod = .automatic
        #expect(draft.assignmentName == "T6 Pilot")

        draft.isNameOverrideEnabled = false
        #expect(draft.assignmentName == "DAF_EFB_T6_PERSONA_AUTO")
    }

    @Test("New distributions reject duplicate Smart Groups")
    func rejectsDuplicateSmartGroups() {
        let distribution = NewDistribution(
            assignmentName: "Duplicate groups",
            smartGroupUUIDs: ["SG-1", "sg-1"]
        )

        #expect(throws: NewDistributionValidationError.duplicateSmartGroups) {
            try distribution.validate(usedSmartGroupUUIDs: [])
        }
    }

    @Test("Configuration validation accepts only scalar values the editor can safely author")
    func validatesSimpleConfiguration() {
        let invalidBoolean = NewDistribution(
            assignmentName: "Invalid Boolean",
            smartGroupUUIDs: ["sg-1"],
            sendConfiguration: true,
            configuration: [NewAppConfiguration(key: "Enabled", value: "yes", type: .boolean)]
        )
        #expect(throws: NewDistributionValidationError.invalidConfigurationValue(key: "Enabled", type: AppConfigurationType.boolean)) {
            try invalidBoolean.validate(usedSmartGroupUUIDs: [])
        }

        let nestedType = NewDistribution(
            assignmentName: "Nested Type",
            smartGroupUUIDs: ["sg-1"],
            sendConfiguration: true,
            configuration: [NewAppConfiguration(key: "Items", value: "one,two", type: .array)]
        )
        #expect(throws: NewDistributionValidationError.unsupportedConfigurationType(AppConfigurationType.array)) {
            try nestedType.validate(usedSmartGroupUUIDs: [])
        }
    }

    @Test("XML property-list import preserves scalar managed app configuration")
    func importsXMLConfiguration() throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>EnableLogging</key>
            <true/>
            <key>RetryCount</key>
            <integer>3</integer>
            <key>ServerURL</key>
            <string>https://config.example</string>
        </dict>
        </plist>
        """#

        let configurations = try AppConfigurationXMLImporter.configurations(from: Data(xml.utf8))
        let values = Dictionary(uniqueKeysWithValues: configurations.map { ($0.key, $0) })
        #expect(values["EnableLogging"]?.value == "true")
        #expect(values["EnableLogging"]?.type == .boolean)
        #expect(values["RetryCount"]?.value == "3")
        #expect(values["RetryCount"]?.type == .integer)
        #expect(values["ServerURL"]?.value == "https://config.example")
        #expect(values["ServerURL"]?.type == .string)
    }
}

@Suite("Assignment comparator")
struct AssignmentComparatorTests {
    private func rule(_ edit: (inout [String: JSONValue]) -> Void) -> AssignmentRuleDocument {
        var raw = MockUEMService.sampleRule().raw
        var assignments = raw["assignments"]?.arrayValue ?? []
        var distribution = assignments[0]["distribution"]?.objectValue ?? [:]
        edit(&distribution)
        assignments[0]["distribution"] = .object(distribution)
        raw["assignments"] = .array(assignments)
        return AssignmentRuleDocument(raw: raw)
    }

    @Test("Identical rules (ignoring identifiers) match")
    func identical() {
        let expected = MockUEMService.sampleRule()
        #expect(AssignmentComparator.compare(expected: expected, actual: expected.preparedForTransfer()).isEmpty)
    }

    @Test("Detects smart group, delivery, and config differences")
    func detectsDifferences() {
        let actual = rule { distribution in
            distribution["smart_groups"] = .array([.string("sg-other")])
            distribution["app_delivery_method"] = .string("ON_DEMAND")
            distribution["application_configuration"] = .array([
                .object(["key": .string("ServerURL"), "value": .string("https://wrong"), "type": .string("STRING")]),
                .object(["key": .string("Extra"), "value": .string("1"), "type": .string("STRING")])
            ])
        }
        let kinds = AssignmentComparator.compare(expected: MockUEMService.sampleRule(), actual: actual).map(\.kind)
        #expect(kinds.contains(.smartGroups))
        #expect(kinds.contains(.deliveryMethod))
        #expect(kinds.filter { $0 == .configuration }.count == 3) // changed, missing EnableLogging, added Extra
    }

    @Test("Detects missing and unexpected assignment groups")
    func detectsGroupChanges() {
        let expected = MockUEMService.sampleRule()
        #expect(AssignmentComparator.compare(expected: expected, actual: .empty).filter { $0.kind == .missingAssignment }.count == 2)
        #expect(AssignmentComparator.compare(expected: .empty, actual: expected).filter { $0.kind == .unexpectedAssignment }.count == 2)
    }

    @Test("Detects exclusion changes")
    func detectsExclusions() {
        var actual = MockUEMService.sampleRule()
        actual.raw["excluded_smart_groups"] = .array([.string("sg-excluded")])
        #expect(AssignmentComparator.compare(expected: MockUEMService.sampleRule(), actual: actual).map(\.kind) == [.exclusions])
    }
}

@Suite("Versions and requests")
struct VersionAndRequestTests {
    @Test("Compares dotted versions numerically", arguments: [
        ("1.10.0", "1.9.9", ComparisonResult.orderedDescending),
        ("1.0", "1.0.0", .orderedSame),
        ("2.0.1", "2.0.10", .orderedAscending),
        ("3.0.0.0", "3", .orderedSame),
        ("1.2.3-beta", "1.2.3", .orderedSame)
    ])
    func compare(lhs: String, rhs: String, expected: ComparisonResult) {
        #expect(VersionComparator.compare(lhs, rhs) == expected)
    }

    @Test("begininstall body uses UEM field names and carries over assignments")
    func beginInstallEncoding() throws {
        let request = BeginInstallRequest(blobID: 12, applicationName: "App",
                                          supportedModels: BeginInstallRequest.supportedModels(forDeviceFamilies: [2]),
                                          pushMode: "OnDemand", locationGroupID: 570, fileName: "App.ipa")
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        #expect(json["BlobId"] == .int(12))
        #expect(json["DeviceType"] == .string("Apple"))
        #expect(json["LocationGroupId"] == .int(570))
        #expect(json["CarryOverAssignments"] == .bool(true))
        #expect(json["UploadViaLink"] == .bool(false))
        #expect(json["SupportedModels"]?["Model"]?.arrayValue?.count == 1)
    }

    @Test("Maps UIDeviceFamily to UEM model IDs", arguments: [
        ([1], [1, 3, 2]),
        ([2], [2]),
        ([1, 2], [1, 3, 2]),
        ([], [1, 3, 2])
    ])
    func supportedModels(families: [Int], expected: [Int]) {
        let models = BeginInstallRequest.supportedModels(forDeviceFamilies: families).model ?? []
        #expect(models.compactMap(\.modelID) == expected)
    }
}

@Suite("Server validation")
struct ServerValidationTests {
    @Test("Normalizes API URLs", arguments: [
        ("as1234.awmdm.com", "https://as1234.awmdm.com"),
        ("https://as1234.awmdm.com/", "https://as1234.awmdm.com"),
        ("https://as1234.awmdm.com/API/", "https://as1234.awmdm.com"),
        ("  https://uem.example.mil/api  ", "https://uem.example.mil"),
        ("https://uem.example.mil:8443/airwatch/api?x=1#y", "https://uem.example.mil:8443/airwatch")
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try ServerValidator.normalizedAPIBase(input).absoluteString == expected)
    }

    @Test("Rejects insecure or malformed URLs")
    func rejectsBadURLs() {
        #expect(throws: ServerValidationError.insecureURL) { try ServerValidator.normalizedAPIBase("http://uem.example.mil") }
        #expect(throws: ServerValidationError.invalidAPIURL) { try ServerValidator.normalizedAPIBase("") }
        #expect(throws: ServerValidationError.invalidAPIURL) { try ServerValidator.normalizedAPIBase("https://user:pw@uem.example.mil") }
        #expect(throws: ServerValidationError.invalidTokenURL) { try ServerValidator.tokenURL("http://na.uemauth.workspaceone.com/connect/token") }
    }

    @Test("Basic auth requires username, password and tenant code")
    func basicValidation() {
        let profile = TestSupport.server(auth: .basic)
        #expect(Set(ServerValidator.validate(profile, secrets: ServerSecrets())) == [.missingPassword, .missingTenantCode])
        #expect(ServerValidator.validate(profile, secrets: ServerSecrets(password: "p", tenantCode: "k")).isEmpty)
    }

    @Test("OAuth requires client credentials and a valid token URL")
    func oauthValidation() {
        var profile = TestSupport.server(auth: .oauth)
        #expect(ServerValidator.validate(profile, secrets: ServerSecrets()) == [.missingClientSecret])
        #expect(ServerValidator.validate(profile, secrets: ServerSecrets(clientSecret: "s")).isEmpty)
        profile.oauthRegion = .custom
        profile.customTokenURL = "not a url"
        #expect(ServerValidator.validate(profile, secrets: ServerSecrets(clientSecret: "s")) == [.invalidTokenURL])
    }

    @Test("Requires name and organization group")
    func requiredFields() {
        var profile = TestSupport.server()
        profile.name = " "
        profile.organizationGroupID = 0
        let errors = ServerValidator.validate(profile, secrets: ServerSecrets(password: "p", tenantCode: "k"))
        #expect(errors.contains(.missingName))
        #expect(errors.contains(.invalidOrganizationGroup))
    }

    @Test("Region presets point at workspaceone.com token endpoints")
    func regionPresets() {
        for region in OAuthRegion.allCases where region != .custom {
            let url = URL(string: region.tokenURL ?? "")
            #expect(url?.scheme == "https")
            #expect(url?.host()?.hasSuffix(".uemauth.workspaceone.com") == true)
            #expect(url?.path() == "/connect/token")
        }
    }
}

@Suite("IPA staging")
struct IPAStagerTests {
    @Test("Sanitizes file names", arguments: [
        ("MissionPlanner.ipa", "MissionPlanner.ipa"),
        ("../../etc/passwd.ipa", "etcpasswd.ipa"),
        ("App:Name?.IPA", "AppName.IPA"),
        (".hidden.ipa", "hidden.ipa"),
        ("noext", "noext.ipa"),
        (".ipa", "app.ipa")
    ])
    func sanitize(input: String, expected: String) {
        #expect(IPAStager.sanitizedFileName(input) == expected)
    }

    @Test("Stages a copy and extracts metadata")
    func stagesCopy() async throws {
        let source = try TestSupport.write(ZipFixtureWriter.ipa(bundleID: "mil.afrc.stage"), named: "Stage.ipa")
        let staged = try await IPAStager.stage(source)
        defer { IPAStager.discard(staged.url) }
        #expect(staged.metadata.bundleIdentifier == "mil.afrc.stage")
        #expect(staged.url != source)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(staged.url.path.hasPrefix(IPAStager.stagingRoot.path))
    }

    @Test("Cleans up when staging an invalid IPA")
    func cleansUpOnFailure() async throws {
        let source = try TestSupport.write(Data("not a zip".utf8), named: "Broken.ipa")
        await #expect(throws: (any Error).self) { try await IPAStager.stage(source) }
    }

    @Test("Discard refuses paths outside the staging area")
    func discardIsScoped() throws {
        let outside = try TestSupport.write(Data([1]), named: "keep.ipa")
        IPAStager.discard(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
