import Foundation

/// Subset of the UEM `ApplicationEntity` / `InternalApplicationEntity` we rely on.
///
/// UEM returns this entity from more than one endpoint and its optional fields are not
/// represented consistently across releases. In particular, `Id` may be a number,
/// string, or `{ "Value": number }` object, and `begininstall` can wrap the entity.
nonisolated struct UEMApplication: Decodable, Hashable, Sendable {
    nonisolated struct EntityID: Codable, Hashable, Sendable {
        var value: Int?

        init(value: Int? = nil) {
            self.value = value
        }

        enum CodingKeys: String, CodingKey { case value = "Value" }

        init(from decoder: Decoder) throws {
            let response = try JSONValue(from: decoder)
            guard let value = Self.integer(from: response) else {
                throw DecodingError.typeMismatch(
                    EntityID.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected an integer UEM entity ID.")
                )
            }
            self.value = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(value, forKey: .value)
        }

        private static func integer(from input: JSONValue) -> Int? {
            if let number = input.intValue { return number }
            guard let object = input.objectValue else { return nil }
            for key in ["Value", "Id", "ID", "ApplicationId", "ApplicationID"] {
                if let nested = value([key], in: object), let number = integer(from: nested) {
                    return number
                }
            }
            return nil
        }

        private static func value(_ keys: [String], in object: [String: JSONValue]) -> JSONValue? {
            for key in keys {
                if let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                    return match.value
                }
            }
            return nil
        }
    }

    nonisolated struct SupportedModels: Codable, Hashable, Sendable {
        var model: [DeviceModel]?
        enum CodingKeys: String, CodingKey { case model = "Model" }
    }

    nonisolated struct DeviceModel: Codable, Hashable, Sendable {
        var modelID: Int?
        var modelName: String?
        enum CodingKeys: String, CodingKey {
            case modelID = "ModelId"
            case modelName = "ModelName"
        }
    }

    var applicationName: String?
    var bundleID: String?
    var appVersion: String?
    var actualFileVersion: String?
    var status: String?
    var platform: Int?
    var pushMode: String?
    var locationGroupID: Int?
    var assignedDeviceCount: Int?
    var installedDeviceCount: Int?
    var supportedModels: SupportedModels?
    var description: String?
    var entityID: EntityID?
    var uuid: String?

    init(applicationName: String? = nil, bundleID: String? = nil, appVersion: String? = nil,
         actualFileVersion: String? = nil, status: String? = nil, platform: Int? = nil,
         pushMode: String? = nil, locationGroupID: Int? = nil, assignedDeviceCount: Int? = nil,
         installedDeviceCount: Int? = nil, supportedModels: SupportedModels? = nil,
         description: String? = nil, entityID: EntityID? = nil, uuid: String? = nil) {
        self.applicationName = applicationName
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.actualFileVersion = actualFileVersion
        self.status = status
        self.platform = platform
        self.pushMode = pushMode
        self.locationGroupID = locationGroupID
        self.assignedDeviceCount = assignedDeviceCount
        self.installedDeviceCount = installedDeviceCount
        self.supportedModels = supportedModels
        self.description = description
        self.entityID = entityID
        self.uuid = uuid
    }

    init(from decoder: Decoder) throws {
        try self.init(responseValue: JSONValue(from: decoder))
    }

    /// Parses the direct response and the entity envelopes returned by UEM endpoints.
    init(responseValue: JSONValue) throws {
        guard let object = Self.applicationObject(in: responseValue) else {
            if responseValue.arrayValue?.isEmpty == true {
                self.init()
                return
            }
            if case .null = responseValue {
                self.init()
                return
            }
            throw DecodingError.typeMismatch(
                UEMApplication.self,
                .init(codingPath: [], debugDescription: "Expected an application object or envelope.")
            )
        }

        let models = Self.deviceModels(from: Self.value(["SupportedModels"], in: object))
        self.init(
            applicationName: Self.string(from: Self.value(["ApplicationName", "Name"], in: object)),
            bundleID: Self.string(from: Self.value(["BundleId", "BundleID", "BundleIdentifier"], in: object)),
            appVersion: Self.string(from: Self.value(["AppVersion", "Version"], in: object)),
            actualFileVersion: Self.string(from: Self.value(["ActualFileVersion", "FileVersion"], in: object)),
            status: Self.string(from: Self.value(["Status", "ApplicationStatus"], in: object)),
            platform: Self.integer(from: Self.value(["Platform", "PlatformId"], in: object)),
            pushMode: Self.string(from: Self.value(["PushMode"], in: object)),
            locationGroupID: Self.integer(from: Self.value(["LocationGroupId", "LocationGroupID"], in: object)),
            assignedDeviceCount: Self.integer(from: Self.value(["AssignedDeviceCount"], in: object)),
            installedDeviceCount: Self.integer(from: Self.value(["InstalledDeviceCount"], in: object)),
            supportedModels: models.map(SupportedModels.init(model:)),
            description: Self.string(from: Self.value(["Description"], in: object)),
            entityID: Self.integer(from: Self.value(["Id", "ID", "ApplicationId"], in: object)).map(EntityID.init(value:)),
            uuid: Self.string(from: Self.value(["Uuid", "UUID", "ApplicationUuid"], in: object))
        )
    }

    var id: Int? { entityID?.value }

    var isActive: Bool { status?.caseInsensitiveCompare("Active") == .orderedSame }

    /// Version shown in the console's "App Version" column.
    var displayVersion: String { actualFileVersion ?? appVersion ?? "?" }

    private static func applicationObject(in payload: JSONValue) -> [String: JSONValue]? {
        switch payload {
        case .object(let object):
            if hasApplicationFields(object) { return object }
            for key in [
                "Application", "InternalApplication", "ApplicationEntity", "InternalApplicationEntity",
                "Entity", "Result", "Data", "Value"
            ] {
                if let nested = value([key], in: object), let resolved = applicationObject(in: nested) {
                    return resolved
                }
            }
            // A successful asynchronous create can contain only a status/message. Returning
            // this partial entity lets the deployment engine safely locate the new app.
            return object
        case .array(let values):
            let candidates = values.compactMap { applicationObject(in: $0) }
            return candidates.first(where: hasApplicationFields) ?? candidates.first
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let identifier = integer(from: .string(trimmed)) {
                return ["Id": .int(Int64(identifier))]
            }
            // A few UEM builds acknowledge an asynchronous create with just its UUID.
            // Restrict this to real UUIDs so a status message cannot be mistaken for an app.
            if UUID(uuidString: trimmed) != nil {
                return ["Uuid": .string(trimmed)]
            }
            return nil
        default:
            guard let identifier = integer(from: payload) else { return nil }
            return ["Id": .int(Int64(identifier))]
        }
    }

    private static func hasApplicationFields(_ object: [String: JSONValue]) -> Bool {
        value([
            "Id", "Uuid", "ApplicationName", "BundleId", "BundleIdentifier", "AppVersion", "ApplicationId"
        ], in: object) != nil
    }

    private static func value(_ keys: [String], in object: [String: JSONValue]) -> JSONValue? {
        for key in keys {
            if let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                return match.value
            }
        }
        return nil
    }

    private static func string(from value: JSONValue?) -> String? {
        value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func integer(from input: JSONValue?) -> Int? {
        guard let input else { return nil }
        if let number = input.intValue { return number }
        guard let object = input.objectValue else { return nil }
        return integer(from: value(["Value", "Id", "ID"], in: object))
    }

    private static func deviceModels(from value: JSONValue?) -> [DeviceModel]? {
        guard let value else { return nil }

        let values: [JSONValue]
        switch value {
        case .array(let items):
            values = items
        case .object(let object):
            if let models = Self.value(["Model", "Models"], in: object) {
                values = models.arrayValue ?? [models]
            } else {
                values = [value]
            }
        default:
            return nil
        }

        let models = values.compactMap { value -> DeviceModel? in
            guard let object = value.objectValue else { return nil }
            let modelID = integer(from: Self.value(["ModelId", "ModelID", "Id"], in: object))
            let modelName = string(from: Self.value(["ModelName", "Name"], in: object))
            guard modelID != nil || modelName != nil else { return nil }
            return DeviceModel(modelID: modelID, modelName: modelName)
        }
        return models.isEmpty ? nil : models
    }
}

nonisolated struct UEMApplicationSearchResult: Decodable, Sendable {
    var application: [UEMApplication]?
    var total: Int?

    init(from decoder: Decoder) throws {
        let response = try JSONValue(from: decoder)
        let catalog = try Self.catalog(from: response)
        application = catalog.applications
        total = catalog.total ?? application?.count
    }

    /// Search responses are normally `{ "Application": [...] }`, but some UEM releases
    /// wrap the catalog in `Result` or `Data`, and a one-item result can be a singleton.
    private static func catalog(from value: JSONValue) throws -> (applications: [UEMApplication]?, total: Int?) {
        switch value {
        case .null:
            return ([], nil)
        case .array(let values):
            var applications: [UEMApplication] = []
            for item in values {
                let nested = try catalog(from: item)
                if let nestedApplications = nested.applications {
                    applications.append(contentsOf: nestedApplications)
                }
            }
            return (applications, nil)
        case .object(let object):
            let total = integer(from: self.value(["Total", "Count"], in: object))
            if looksLikeApplication(object) {
                return ([try UEMApplication(responseValue: value)], total)
            }
            if let direct = self.value(["Application", "Applications", "Items", "Results"], in: object) {
                let nested = try catalog(from: direct)
                return (nested.applications, total ?? nested.total)
            }
            for key in ["Result", "Data", "Value", "Response"] {
                if let nestedValue = self.value([key], in: object) {
                    let nested = try catalog(from: nestedValue)
                    if nested.applications != nil {
                        return (nested.applications, total ?? nested.total)
                    }
                }
            }
            return (nil, total)
        default:
            return (nil, nil)
        }
    }

    private static func looksLikeApplication(_ object: [String: JSONValue]) -> Bool {
        value([
            "Id", "Uuid", "ApplicationName", "BundleId", "BundleIdentifier", "AppVersion", "ApplicationId"
        ], in: object) != nil
    }

    private static func integer(from value: JSONValue?) -> Int? {
        guard let value else { return nil }
        if let number = value.intValue { return number }
        guard let object = value.objectValue else { return nil }
        return integer(from: Self.value(["Value", "Id", "ID"], in: object))
    }

    private static func value(_ keys: [String], in object: [String: JSONValue]) -> JSONValue? {
        for key in keys {
            if let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                return match.value
            }
        }
        return nil
    }
}

nonisolated struct UEMBlobResponse: Decodable, Sendable {
    var value: Int?
    var id: Int?
    var uuid: String?

    init(from decoder: Decoder) throws {
        let response = try JSONValue(from: decoder)
        value = Self.integer(from: response)
        id = nil
        uuid = Self.string(from: response)
    }

    var blobID: Int? { value ?? id }

    private static func integer(from input: JSONValue) -> Int? {
        if let number = input.intValue { return number }
        guard let object = input.objectValue else { return nil }
        for key in ["Value", "Id", "ID", "BlobId", "BlobID", "Blob", "Result", "Data"] {
            if let nested = value([key], in: object), let number = integer(from: nested) {
                return number
            }
        }
        return nil
    }

    private static func string(from input: JSONValue) -> String? {
        guard let object = input.objectValue else { return nil }
        for key in ["Uuid", "UUID", "BlobUuid", "BlobUUID", "Blob", "Result", "Data"] {
            if let nested = value([key], in: object) {
                if let string = nested.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                    return string
                }
                if let string = string(from: nested) { return string }
            }
        }
        return nil
    }

    private static func value(_ keys: [String], in object: [String: JSONValue]) -> JSONValue? {
        for key in keys {
            if let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                return match.value
            }
        }
        return nil
    }
}

nonisolated struct UEMOrganizationGroup: Codable, Hashable, Sendable, Identifiable {
    var name: String?
    var groupID: String?
    var entityID: UEMApplication.EntityID?
    var uuid: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case groupID = "GroupId"
        case entityID = "Id"
        case uuid = "Uuid"
    }

    var id: Int { entityID?.value ?? 0 }
}

nonisolated struct UEMOrganizationGroupSearchResult: Codable, Sendable {
    var locationGroups: [UEMOrganizationGroup]?
    enum CodingKeys: String, CodingKey { case locationGroups = "LocationGroups" }
}

nonisolated struct UEMSmartGroupSearchResult: Codable, Sendable {
    nonisolated struct SmartGroup: Codable, Sendable {
        var name: String?
        var smartGroupUUID: String?
        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case smartGroupUUID = "SmartGroupUuid"
        }
    }

    var smartGroups: [SmartGroup]?
    enum CodingKeys: String, CodingKey { case smartGroups = "SmartGroups" }
}

/// Body for `POST /api/mam/apps/internal/begininstall`.
nonisolated struct BeginInstallRequest: Codable, Hashable, Sendable {
    var blobID: Int
    var deviceType: String = "Apple"
    var applicationName: String
    var supportedModels: UEMApplication.SupportedModels
    var pushMode: String
    var locationGroupID: Int
    var fileName: String
    var description: String?
    var carryOverAssignments: Bool = true
    var enableProvisioning: Bool = false
    var uploadViaLink: Bool = false

    enum CodingKeys: String, CodingKey {
        case blobID = "BlobId"
        case deviceType = "DeviceType"
        case applicationName = "ApplicationName"
        case supportedModels = "SupportedModels"
        case pushMode = "PushMode"
        case locationGroupID = "LocationGroupId"
        case fileName = "FileName"
        case description = "Description"
        case carryOverAssignments = "CarryOverAssignments"
        case enableProvisioning = "EnableProvisioning"
        case uploadViaLink = "UploadViaLink"
    }

    /// UEM Apple model IDs: 1 = iPhone, 2 = iPad, 3 = iPod Touch.
    static func supportedModels(forDeviceFamilies families: [Int]) -> UEMApplication.SupportedModels {
        var models: [UEMApplication.DeviceModel] = []
        let families = families.isEmpty ? [1, 2] : families
        if families.contains(1) {
            models.append(.init(modelID: 1, modelName: "iPhone"))
            models.append(.init(modelID: 3, modelName: "iPod Touch"))
        }
        if families.contains(2) || families.contains(1) {
            // iPhone apps also run on iPad, matching the console's default selection.
            models.append(.init(modelID: 2, modelName: "iPad"))
        }
        return .init(model: models)
    }
}

/// Standard UEM error payload.
nonisolated struct UEMErrorBody: Codable, Sendable {
    var errorCode: Int?
    var message: String?
    var activityID: String?

    enum CodingKeys: String, CodingKey {
        case errorCode
        case message
        case activityID = "activityId"
    }
}

nonisolated struct OAuthTokenResponse: Codable, Sendable {
    var accessToken: String
    var expiresIn: Int?
    var tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Versions

nonisolated enum VersionComparator {
    /// Compares dotted numeric versions (`1.10.0` > `1.9.3`); missing components count as zero.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix(while: \.isNumber)) ?? 0
        }
    }
}
