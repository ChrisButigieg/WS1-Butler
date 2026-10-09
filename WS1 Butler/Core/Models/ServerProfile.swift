import Foundation

/// Deployment tier of a UEM environment. Drives color coding throughout the UI.
nonisolated enum ServerEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case development = "DEV"
    case test = "TEST"
    case production = "PROD"
    case other = "OPS"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .development: "Development"
        case .test: "Test"
        case .production: "Production"
        case .other: "Other"
        }
    }
}

nonisolated enum AuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case oauth = "OAuth 2.0"
    case basic = "Basic"

    var id: String { rawValue }
}

/// Well-known Workspace ONE UEM OAuth token endpoints (SaaS). On-premises and
/// dedicated/government tenants can supply a custom URL.
nonisolated enum OAuthRegion: String, Codable, CaseIterable, Sendable, Identifiable {
    case northAmerica = "NA"
    case emea = "EMEA"
    case apac = "APAC"
    case uat = "UAT"
    case custom = "Custom"

    var id: String { rawValue }

    var tokenURL: String? {
        switch self {
        case .northAmerica: "https://na.uemauth.workspaceone.com/connect/token"
        case .emea: "https://emea.uemauth.workspaceone.com/connect/token"
        case .apac: "https://apac.uemauth.workspaceone.com/connect/token"
        case .uat: "https://uat.uemauth.workspaceone.com/connect/token"
        case .custom: nil
        }
    }
}

/// Non-secret configuration of a UEM server. Secrets live in the Keychain (see `ServerSecrets`).
nonisolated struct ServerProfile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var environment: ServerEnvironment = .development
    /// REST API host, e.g. `https://as1234.awmdm.com`.
    var apiURL: String = ""
    var organizationGroupID: Int = 0
    var organizationGroupName: String = ""
    var authMethod: AuthMethod = .oauth
    var username: String = ""
    var oauthRegion: OAuthRegion = .northAmerica
    var customTokenURL: String = ""
    var clientID: String = ""
    var isEnabled: Bool = true

    /// Effective OAuth token endpoint for the selected region.
    var tokenURLString: String {
        oauthRegion.tokenURL ?? customTokenURL
    }

    var displayName: String {
        name.isEmpty ? (URL(string: apiURL)?.host() ?? "Unnamed Server") : name
    }
}

/// Credentials stored in the Keychain, keyed by `ServerProfile.id`.
nonisolated struct ServerSecrets: Codable, Hashable, Sendable {
    var password: String = ""
    var tenantCode: String = ""
    var clientSecret: String = ""

    var isEmpty: Bool { password.isEmpty && tenantCode.isEmpty && clientSecret.isEmpty }
}

// MARK: - Validation

nonisolated enum ServerValidationError: LocalizedError, Equatable, Sendable {
    case missingName
    case invalidAPIURL
    case insecureURL
    case invalidOrganizationGroup
    case missingUsername
    case missingPassword
    case missingTenantCode
    case missingClientID
    case missingClientSecret
    case invalidTokenURL

    var errorDescription: String? {
        switch self {
        case .missingName: "Enter a name for this server."
        case .invalidAPIURL: "Enter a valid API server URL, e.g. https://as1234.awmdm.com."
        case .insecureURL: "Only HTTPS endpoints are allowed."
        case .invalidOrganizationGroup: "Enter the numeric Organization Group ID (use Lookup to find it)."
        case .missingUsername: "Enter the API admin username."
        case .missingPassword: "Enter the API admin password."
        case .missingTenantCode: "Enter the REST API key (aw-tenant-code)."
        case .missingClientID: "Enter the OAuth client ID."
        case .missingClientSecret: "Enter the OAuth client secret."
        case .invalidTokenURL: "Enter a valid HTTPS OAuth token URL."
        }
    }
}

nonisolated enum ServerValidator {
    /// Normalizes user input such as `as1234.awmdm.com/API/` into `https://as1234.awmdm.com`.
    /// Rejects plain HTTP: credentials must never travel unencrypted.
    static func normalizedAPIBase(_ input: String) throws(ServerValidationError) -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalidAPIURL }
        if !text.contains("://") { text = "https://" + text }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { throw .invalidAPIURL }
        guard scheme == "https" else { throw .insecureURL }
        guard components.user == nil, components.password == nil else { throw .invalidAPIURL }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/api") { path.removeLast(4) }
        components.scheme = "https"
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw .invalidAPIURL }
        return url
    }

    static func tokenURL(_ input: String) throws(ServerValidationError) -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url
        else { throw .invalidTokenURL }
        return url
    }

    /// Returns every problem with the profile; empty means it is ready to use.
    static func validate(_ profile: ServerProfile, secrets: ServerSecrets) -> [ServerValidationError] {
        var errors: [ServerValidationError] = []
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.missingName) }
        do { _ = try normalizedAPIBase(profile.apiURL) } catch { errors.append(error) }
        if profile.organizationGroupID <= 0 { errors.append(.invalidOrganizationGroup) }

        switch profile.authMethod {
        case .basic:
            if profile.username.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.missingUsername) }
            if secrets.password.isEmpty { errors.append(.missingPassword) }
            if secrets.tenantCode.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.missingTenantCode) }
        case .oauth:
            if profile.clientID.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.missingClientID) }
            if secrets.clientSecret.isEmpty { errors.append(.missingClientSecret) }
            do { _ = try tokenURL(profile.tokenURLString) } catch { errors.append(error) }
        }
        return errors
    }
}
