import Foundation

nonisolated enum UEMError: LocalizedError, Equatable, Sendable {
    case http(status: Int, message: String?, activityID: String?)
    case authenticationFailed(String)
    case invalidConfiguration(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message, let activityID):
            var text = "HTTP \(status)"
            if let message, !message.isEmpty { text += ": \(message)" }
            if let activityID, !activityID.isEmpty { text += " (activity \(activityID))" }
            return text
        case .authenticationFailed(let reason): return "Authentication failed: \(reason)"
        case .invalidConfiguration(let reason): return reason
        case .unexpectedResponse(let reason): return "Unexpected response from UEM: \(reason)"
        }
    }

    var statusCode: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }
}

/// Operations the deployment pipeline needs from a Workspace ONE UEM server.
protocol UEMService: AnyObject {
    func testConnection() async throws -> UEMOrganizationGroup
    func searchOrganizationGroups(groupID: String) async throws -> [UEMOrganizationGroup]
    func findInternalApps(bundleID: String) async throws -> [UEMApplication]
    func assignmentRule(appUUID: String) async throws -> AssignmentRuleDocument
    func updateAssignmentRule(appUUID: String, rule: AssignmentRuleDocument) async throws
    func smartGroupNames() async throws -> [String: String]
    func uploadBlob(fileURL: URL, fileName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int
    func deleteBlob(id: Int) async throws
    func beginInstall(_ request: BeginInstallRequest) async throws -> UEMApplication
    func retireApp(id: Int) async throws
}

/// REST client for the Workspace ONE UEM MAM / System / MDM APIs (validated against release 2604).
final class UEMClient: UEMService {
    let server: ServerProfile
    private let secrets: ServerSecrets
    private let transport: HTTPTransport
    private let baseURL: URL
    private let retryDelay: Duration
    private let maxRetries: Int

    private var cachedToken: (value: String, expiry: Date)?
    private var tokenTask: Task<String, Error>?

    init(server: ServerProfile, secrets: ServerSecrets, transport: HTTPTransport,
         retryDelay: Duration = .seconds(1), maxRetries: Int = 2) throws {
        self.server = server
        self.secrets = secrets
        self.transport = transport
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
        do {
            baseURL = try ServerValidator.normalizedAPIBase(server.apiURL)
        } catch {
            throw UEMError.invalidConfiguration(error.errorDescription ?? "Invalid API URL")
        }
    }

    // MARK: - UEMService

    func testConnection() async throws -> UEMOrganizationGroup {
        guard server.organizationGroupID > 0 else {
            throw UEMError.invalidConfiguration("Organization Group ID is not set.")
        }
        let data = try await perform(.get, "/api/system/groups/\(server.organizationGroupID)", version: 1)
        return try decode(UEMOrganizationGroup.self, from: data)
    }

    func searchOrganizationGroups(groupID: String) async throws -> [UEMOrganizationGroup] {
        let data = try await perform(.get, "/api/system/groups/search", query: [
            URLQueryItem(name: "groupid", value: groupID)
        ], version: 1)
        guard !data.isEmpty else { return [] }
        return try decode(UEMOrganizationGroupSearchResult.self, from: data).locationGroups ?? []
    }

    func findInternalApps(bundleID: String) async throws -> [UEMApplication] {
        let data = try await perform(.get, "/api/mam/apps/search", query: [
            URLQueryItem(name: "type", value: "App"),
            URLQueryItem(name: "applicationtype", value: "Internal"),
            URLQueryItem(name: "platform", value: "Apple"),
            URLQueryItem(name: "bundleid", value: bundleID),
            URLQueryItem(name: "locationgroupid", value: String(server.organizationGroupID)),
            URLQueryItem(name: "pagesize", value: "500")
        ], version: 1)
        // UEM answers 204 No Content when nothing matches.
        guard !data.isEmpty else { return [] }
        let apps = try decode(UEMApplicationSearchResult.self, from: data).application ?? []
        return apps.filter { $0.bundleID?.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func assignmentRule(appUUID: String) async throws -> AssignmentRuleDocument {
        let data = try await perform(.get, "/api/mam/apps/\(try pathComponent(appUUID))/assignment-rules", version: 2)
        guard !data.isEmpty else { return .empty }
        let json = try decode(JSONValue.self, from: data)
        guard case .object = json else { return .empty }
        return AssignmentRuleDocument(raw: json)
    }

    func updateAssignmentRule(appUUID: String, rule: AssignmentRuleDocument) async throws {
        let body = try JSONEncoder().encode(rule.raw)
        _ = try await perform(.put, "/api/mam/apps/\(try pathComponent(appUUID))/assignment-rules",
                              version: 2, body: body, retryable: false)
    }

    func smartGroupNames() async throws -> [String: String] {
        let data = try await perform(.get, "/api/mdm/smartgroups/search", query: [
            URLQueryItem(name: "pagesize", value: "1000")
        ], version: 1)
        guard !data.isEmpty else { return [:] }
        let groups = try decode(UEMSmartGroupSearchResult.self, from: data).smartGroups ?? []
        var names: [String: String] = [:]
        for group in groups {
            if let uuid = group.smartGroupUUID?.lowercased(), let name = group.name { names[uuid] = name }
        }
        return names
    }

    func uploadBlob(fileURL: URL, fileName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let url = try makeURL("/api/mam/blobs/uploadblob", query: [
            URLQueryItem(name: "fileName", value: fileName),
            URLQueryItem(name: "organizationGroupId", value: String(server.organizationGroupID)),
            URLQueryItem(name: "moduleType", value: "Application")
        ])

        var attempt = 0
        while true {
            var request = try await authorizedRequest(url: url, method: .post, version: 1)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 6 * 60 * 60
            let (data, response) = try await transport.upload(request, fromFile: fileURL, progress: progress)
            if response.statusCode == 401, server.authMethod == .oauth, attempt == 0 {
                attempt += 1
                invalidateToken()
                continue
            }
            try validate(response, data: data)
            let blob = try decode(UEMBlobResponse.self, from: data)
            guard let id = blob.blobID, id > 0 else { throw UEMError.unexpectedResponse("blob upload returned no ID") }
            return id
        }
    }

    func deleteBlob(id: Int) async throws {
        _ = try await perform(.delete, "/api/mam/blobs/blob/\(id)", version: 1, retryable: false)
    }

    func beginInstall(_ request: BeginInstallRequest) async throws -> UEMApplication {
        let body = try JSONEncoder().encode(request)
        let data = try await perform(.post, "/api/mam/apps/internal/begininstall", version: 1, body: body, retryable: false)
        guard !data.isEmpty else { throw UEMError.unexpectedResponse("begininstall returned no application") }
        return try decode(UEMApplication.self, from: data)
    }

    func retireApp(id: Int) async throws {
        _ = try await perform(.post, "/api/mam/apps/internal/\(id)/retire", version: 1, body: Data(), retryable: false)
    }

    // MARK: - Request pipeline

    enum Method: String { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }

    private func perform(_ method: Method, _ path: String, query: [URLQueryItem] = [], version: Int,
                         body: Data? = nil, retryable: Bool = true) async throws -> Data {
        let url = try makeURL(path, query: query)
        var attempt = 0
        var refreshedToken = false

        while true {
            try Task.checkCancellation()
            var request = try await authorizedRequest(url: url, method: method, version: version)
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            do {
                let (data, response) = try await transport.send(request)
                if response.statusCode == 401, server.authMethod == .oauth, !refreshedToken {
                    // Token may have been revoked or expired early: refresh once.
                    refreshedToken = true
                    invalidateToken()
                    continue
                }
                if retryable, attempt < maxRetries, [429, 502, 503, 504].contains(response.statusCode) {
                    attempt += 1
                    try await Task.sleep(for: retryDelay * attempt)
                    continue
                }
                try validate(response, data: data)
                return data
            } catch let error as URLError where retryable && attempt < maxRetries && Self.isTransient(error) {
                attempt += 1
                try await Task.sleep(for: retryDelay * attempt)
            }
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]
            .contains(error.code)
    }

    func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw UEMError.invalidConfiguration("Invalid API URL")
        }
        components.path = components.path + path
        if !query.isEmpty {
            components.queryItems = query
            // `+` is legal in query strings but many servers decode it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw UEMError.invalidConfiguration("Could not build request URL") }
        return url
    }

    /// Rejects identifiers containing path separators or other unsafe characters.
    private func pathComponent(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw UEMError.unexpectedResponse("invalid identifier '\(value.prefix(40))'")
        }
        return value
    }

    func authorizedRequest(url: URL, method: Method, version: Int) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json;version=\(version)", forHTTPHeaderField: "Accept")
        request.setValue("WS1Butler/1.0", forHTTPHeaderField: "User-Agent")

        switch server.authMethod {
        case .basic:
            request.setValue(Self.basicAuthorization(username: server.username, password: secrets.password),
                             forHTTPHeaderField: "Authorization")
        case .oauth:
            let token = try await accessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let tenantCode = secrets.tenantCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tenantCode.isEmpty {
            request.setValue(tenantCode, forHTTPHeaderField: "aw-tenant-code")
        }
        return request
    }

    static func basicAuthorization(username: String, password: String) -> String {
        let raw = "\(username):\(password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let body = try? JSONDecoder().decode(UEMErrorBody.self, from: data)
            var message = body?.message
            if message == nil, response.statusCode == 401 {
                message = "Unauthorized. Check credentials, API key, and admin role permissions."
            } else if message == nil, response.statusCode == 403 {
                message = "Forbidden. The admin account or OAuth client lacks permission for this action."
            }
            throw UEMError.http(status: response.statusCode,
                                message: message.map { String($0.prefix(400)) },
                                activityID: body?.activityID)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw UEMError.unexpectedResponse("could not decode \(T.self)")
        }
    }

    // MARK: - OAuth

    private func invalidateToken() {
        cachedToken = nil
    }

    private func accessToken() async throws -> String {
        if let cachedToken, cachedToken.expiry > Date() { return cachedToken.value }
        // Coalesce concurrent refreshes into a single token request.
        if let tokenTask { return try await tokenTask.value }

        let task = Task { try await self.fetchToken() }
        tokenTask = task
        defer { tokenTask = nil }
        let token = try await task.value
        return token
    }

    private func fetchToken() async throws -> String {
        let tokenURL: URL
        do {
            tokenURL = try ServerValidator.tokenURL(server.tokenURLString)
        } catch {
            throw UEMError.invalidConfiguration(error.errorDescription ?? "Invalid token URL")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            ("grant_type", "client_credentials"),
            ("client_id", server.clientID),
            ("client_secret", secrets.clientSecret)
        ])

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw UEMError.authenticationFailed("token endpoint returned HTTP \(response.statusCode)")
        }
        guard let token = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data),
              !token.accessToken.isEmpty
        else { throw UEMError.authenticationFailed("token endpoint returned no access token") }

        // Refresh a minute early to avoid using a token that expires mid-request.
        let lifetime = max(60, token.expiresIn ?? 3600)
        cachedToken = (token.accessToken, Date().addingTimeInterval(TimeInterval(lifetime - 60)))
        return token.accessToken
    }

    static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
