import Foundation

/// Subset of the UEM `ApplicationEntity` / `InternalApplicationEntity` we rely on.
/// Every field is optional because UEM omits empty values.
nonisolated struct UEMApplication: Codable, Hashable, Sendable {
    nonisolated struct EntityID: Codable, Hashable, Sendable {
        var value: Int?
        enum CodingKeys: String, CodingKey { case value = "Value" }
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

    enum CodingKeys: String, CodingKey {
        case applicationName = "ApplicationName"
        case bundleID = "BundleId"
        case appVersion = "AppVersion"
        case actualFileVersion = "ActualFileVersion"
        case status = "Status"
        case platform = "Platform"
        case pushMode = "PushMode"
        case locationGroupID = "LocationGroupId"
        case assignedDeviceCount = "AssignedDeviceCount"
        case installedDeviceCount = "InstalledDeviceCount"
        case supportedModels = "SupportedModels"
        case description = "Description"
        case entityID = "Id"
        case uuid = "Uuid"
    }

    var id: Int? { entityID?.value }

    var isActive: Bool { status?.caseInsensitiveCompare("Active") == .orderedSame }

    /// Version shown in the console's "App Version" column.
    var displayVersion: String { actualFileVersion ?? appVersion ?? "?" }
}

nonisolated struct UEMApplicationSearchResult: Codable, Sendable {
    var application: [UEMApplication]?
    var total: Int?

    enum CodingKeys: String, CodingKey {
        case application = "Application"
        case total = "Total"
    }
}

nonisolated struct UEMBlobResponse: Codable, Sendable {
    var value: Int?
    var id: Int?
    var uuid: String?

    enum CodingKeys: String, CodingKey {
        case value = "Value"
        case id
        case uuid
    }

    var blobID: Int? { value ?? id }
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
