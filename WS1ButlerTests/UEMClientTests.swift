import Foundation
import Testing
@testable import WS1Butler

/// Scripted HTTP transport that records every request.
final class MockTransport: HTTPTransport {
    struct Response {
        var status: Int
        var body: Data
        init(_ status: Int, _ body: String = "") {
            self.status = status
            self.body = Data(body.utf8)
        }
    }

    private(set) var requests: [URLRequest] = []
    private(set) var uploadedFiles: [URL] = []
    var handler: (URLRequest) throws -> Response = { _ in Response(200, "{}") }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try respond(to: request)
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        uploadedFiles.append(fileURL)
        progress(1)
        return try respond(to: request)
    }

    private func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let response = try handler(request)
        let url = request.url ?? URL(filePath: "/")
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)
        guard let http else { throw URLError(.badServerResponse) }
        return (response.body, http)
    }

    var apiRequests: [URLRequest] { requests.filter { $0.url?.path().hasPrefix("/api/") == true } }
    var tokenRequests: [URLRequest] { requests.filter { $0.url?.path() == "/connect/token" } }
}

@Suite("UEM REST client")
struct UEMClientTests {
    private func makeClient(auth: AuthMethod = .basic, transport: MockTransport,
                            secrets: ServerSecrets = ServerSecrets(password: "p@ss:word", tenantCode: "TENANT-KEY", clientSecret: "s3cr3t&=")) throws -> UEMClient {
        try UEMClient(server: TestSupport.server(auth: auth), secrets: secrets, transport: transport, retryDelay: .zero)
    }

    @Test("Basic auth sends Authorization, aw-tenant-code and versioned Accept headers")
    func basicHeaders() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(200, #"{"Application":[]}"#) }
        let client = try makeClient(transport: transport)
        _ = try await client.findInternalApps(bundleID: "mil.afrc.app")

        let request = try #require(transport.requests.first)
        let expected = "Basic " + Data("api-admin:p@ss:word".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        #expect(request.value(forHTTPHeaderField: "aw-tenant-code") == "TENANT-KEY")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json;version=1")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host() == "as1234.awmdm.com")
        #expect(request.url?.path() == "/api/mam/apps/search")
        let query = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        #expect(query.contains(URLQueryItem(name: "bundleid", value: "mil.afrc.app")))
        #expect(query.contains(URLQueryItem(name: "applicationtype", value: "Internal")))
        #expect(query.contains(URLQueryItem(name: "locationgroupid", value: "570")))
    }

    @Test("App search treats 204 No Content as no results and filters bundle ID exactly")
    func searchFiltering() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(204) }
        let client = try makeClient(transport: transport)
        #expect(try await client.findInternalApps(bundleID: "a").isEmpty)

        transport.handler = { _ in .init(200, #"""
        {"Application":[
          {"ApplicationName":"A","BundleId":"mil.afrc.app","AppVersion":"1.0.0.0","Status":"Active","Id":{"Value":10},"Uuid":"u-10"},
          {"ApplicationName":"B","BundleId":"mil.afrc.app.extra","AppVersion":"1.0.0.0","Status":"Active","Id":{"Value":11},"Uuid":"u-11"}
        ],"Total":2}
        """#) }
        let apps = try await client.findInternalApps(bundleID: "MIL.AFRC.APP")
        #expect(apps.map(\.id) == [10])
        #expect(apps.first?.uuid == "u-10")
        #expect(apps.first?.isActive == true)
    }

    @Test("Search and organization endpoints accept nested, singleton, and primitive entity responses")
    func flexibleCatalogResponses() async throws {
        let transport = MockTransport()
        var searchResponse = 0
        transport.handler = { request in
            if request.url?.path() == "/api/system/groups/570" {
                return .init(200, #"{"Name":"AFRC","Id":"570"}"#)
            }
            defer { searchResponse += 1 }
            if searchResponse == 0 {
                return .init(200, #"{"Result":{"Data":{"Application":{"ApplicationName":"Mission Planner","BundleId":"mil.afrc.app","ActualFileVersion":"1.1.0","Status":"Active","Id":2002,"Uuid":"new-uuid"}}}}"#)
            }
            return .init(200, #"{"ApplicationName":"Mission Planner","BundleId":"mil.afrc.app","ActualFileVersion":"1.1.1","Status":"Active","Id":"2003","Uuid":"newer-uuid"}"#)
        }
        let client = try makeClient(transport: transport)

        let group = try await client.testConnection()
        let wrappedApps = try await client.findInternalApps(bundleID: "mil.afrc.app")
        let singletonApps = try await client.findInternalApps(bundleID: "mil.afrc.app")

        #expect(group.id == 570)
        #expect(wrappedApps.map(\.id) == [2002])
        #expect(singletonApps.map(\.id) == [2003])
    }

    @Test("OAuth fetches one token and reuses it as a Bearer token")
    func oauthTokenReuse() async throws {
        let transport = MockTransport()
        transport.handler = { request in
            if request.url?.path() == "/connect/token" {
                return .init(200, #"{"access_token":"tok-1","expires_in":3600,"token_type":"Bearer"}"#)
            }
            return .init(200, #"{"Name":"AFRC","Id":{"Value":570}}"#)
        }
        let client = try makeClient(auth: .oauth, transport: transport, secrets: ServerSecrets(clientSecret: "s3cr3t&="))
        _ = try await client.testConnection()
        _ = try await client.testConnection()

        #expect(transport.tokenRequests.count == 1)
        let tokenRequest = try #require(transport.tokenRequests.first)
        #expect(tokenRequest.url?.host() == "na.uemauth.workspaceone.com")
        #expect(tokenRequest.httpMethod == "POST")
        #expect(tokenRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: tokenRequest.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "grant_type=client_credentials&client_id=client-123&client_secret=s3cr3t%26%3D")

        #expect(transport.apiRequests.count == 2)
        for request in transport.apiRequests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
            // No tenant code configured → header omitted.
            #expect(request.value(forHTTPHeaderField: "aw-tenant-code") == nil)
        }
    }

    @Test("OAuth refreshes the token once after a 401")
    func oauthRefreshOn401() async throws {
        let transport = MockTransport()
        var tokenCount = 0
        var apiCount = 0
        transport.handler = { request in
            if request.url?.path() == "/connect/token" {
                tokenCount += 1
                return .init(200, #"{"access_token":"tok-\#(tokenCount)","expires_in":3600}"#)
            }
            apiCount += 1
            return apiCount == 1 ? .init(401) : .init(200, #"{"Name":"AFRC","Id":{"Value":570}}"#)
        }
        let client = try makeClient(auth: .oauth, transport: transport, secrets: ServerSecrets(clientSecret: "x"))
        let group = try await client.testConnection()

        #expect(group.name == "AFRC")
        #expect(transport.tokenRequests.count == 2)
        #expect(transport.apiRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
    }

    @Test("OAuth token endpoint failures surface as authentication errors")
    func oauthFailure() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(400, #"{"error":"invalid_client"}"#) }
        let client = try makeClient(auth: .oauth, transport: transport, secrets: ServerSecrets(clientSecret: "x"))
        await #expect(throws: UEMError.authenticationFailed("token endpoint returned HTTP 400")) {
            try await client.testConnection()
        }
        #expect(transport.apiRequests.isEmpty)
    }

    @Test("UEM error payloads become readable errors")
    func errorParsing() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(400, #"{"errorCode":1001,"message":"Application version already exists","activityId":"abc-123"}"#) }
        let client = try makeClient(transport: transport)
        await #expect(throws: UEMError.http(status: 400, message: "Application version already exists", activityID: "abc-123")) {
            _ = try await client.beginInstall(BeginInstallRequest(blobID: 1, applicationName: "A", supportedModels: .init(model: []),
                                                                  pushMode: "Auto", locationGroupID: 570, fileName: "a.ipa"))
        }
    }

    @Test("Begin install accepts production response variants and empty acknowledgements")
    func beginInstallResponseVariants() async throws {
        let transport = MockTransport()
        let responses: [MockTransport.Response] = [
            .init(201, #"{"Id":2002,"Uuid":"new-uuid","Platform":"Apple","SupportedModels":{"Model":{"ModelId":"2","ModelName":"iPad"}}}"#),
            .init(200, #"{"Application":{"Id":{"Value":"2003"},"Uuid":"new-uuid-2","ApplicationName":"Mission Planner","BundleIdentifier":"mil.afrc.app","ActualFileVersion":"1.1.0"}}"#),
            .init(202),
            .init(201, "2004"),
            .init(201, #"{"Result":{"ApplicationEntity":{"Id":"2005","Uuid":"new-uuid-5"}}}"#),
            .init(202, "null"),
            .init(202, " \r\n"),
            .init(202, "3d958f38-246e-4854-a306-189d941ab073")
        ]
        var responseIndex = 0
        transport.handler = { request in
            #expect(request.url?.path() == "/api/mam/apps/internal/begininstall")
            defer { responseIndex += 1 }
            return responses[responseIndex]
        }

        let client = try makeClient(transport: transport)
        let request = BeginInstallRequest(
            blobID: 1,
            applicationName: "Mission Planner",
            supportedModels: .init(model: [.init(modelID: 2, modelName: "iPad")]),
            pushMode: "Auto",
            locationGroupID: 570,
            fileName: "MissionPlanner.ipa"
        )

        let directID = try await client.beginInstall(request)
        let wrappedID = try await client.beginInstall(request)
        let acknowledged = try await client.beginInstall(request)
        let numericID = try await client.beginInstall(request)
        let resultEnvelope = try await client.beginInstall(request)
        let nullAcknowledgement = try await client.beginInstall(request)
        let whitespaceAcknowledgement = try await client.beginInstall(request)
        let uuidAcknowledgement = try await client.beginInstall(request)

        #expect(directID.id == 2002)
        #expect(directID.uuid == "new-uuid")
        #expect(directID.supportedModels?.model?.first?.modelID == 2)
        #expect(wrappedID.id == 2003)
        #expect(wrappedID.bundleID == "mil.afrc.app")
        #expect(wrappedID.displayVersion == "1.1.0")
        #expect(acknowledged.id == nil)
        #expect(acknowledged.uuid == nil)
        #expect(numericID.id == 2004)
        #expect(resultEnvelope.id == 2005)
        #expect(resultEnvelope.uuid == "new-uuid-5")
        #expect(nullAcknowledgement.id == nil)
        #expect(whitespaceAcknowledgement.id == nil)
        #expect(uuidAcknowledgement.uuid == "3d958f38-246e-4854-a306-189d941ab073")
    }

    @Test("Transient failures on GET are retried; POSTs are never retried")
    func retryPolicy() async throws {
        let transport = MockTransport()
        var attempts = 0
        transport.handler = { _ in
            attempts += 1
            return attempts < 3 ? .init(503) : .init(200, #"{"Name":"OG","Id":{"Value":570}}"#)
        }
        let client = try makeClient(transport: transport)
        #expect(try await client.testConnection().name == "OG")
        #expect(attempts == 3)

        attempts = 0
        transport.handler = { _ in attempts += 1; return .init(503) }
        await #expect(throws: UEMError.self) { try await client.retireApp(id: 5) }
        #expect(attempts == 1)
    }

    @Test("Blob upload streams the file with the right query and content type")
    func uploadBlob() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(200, #"{"Value":4242,"uuid":"blob-uuid"}"#) }
        let client = try makeClient(transport: transport)
        let file = try TestSupport.write(Data([1, 2, 3]), named: "My App+1.ipa")
        let id = try await client.uploadBlob(fileURL: file, fileName: "My App+1.ipa") { _ in }

        #expect(id == 4242)
        #expect(transport.uploadedFiles == [file])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/mam/blobs/uploadblob")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        let rawQuery = try #require(request.url?.query(percentEncoded: true))
        #expect(rawQuery.contains("fileName=My%20App%2B1.ipa"))
        #expect(rawQuery.contains("organizationGroupId=570"))
        #expect(rawQuery.contains("moduleType=Application"))
    }

    @Test("Blob upload accepts an enveloped string ID")
    func uploadBlobResponseVariants() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(201, #"{"Result":{"Value":"4243"}}"#) }
        let client = try makeClient(transport: transport)
        let file = try TestSupport.write(Data([1]), named: "App.ipa")

        let id = try await client.uploadBlob(fileURL: file, fileName: "App.ipa") { _ in }

        #expect(id == 4243)
    }

    @Test("Assignment rules use API v2 and PUT preserves unmodeled fields")
    func assignmentRules() async throws {
        let transport = MockTransport()
        let ruleJSON = #"{"id":7,"assignments":[{"priority":0,"distribution":{"name":"G","smart_groups":["sg"],"app_delivery_method":"AUTO","application_configuration":[]},"tunnel":{"per_app_vpn_profile_uuid":"vpn-1"}}],"excluded_smart_groups":[]}"#
        transport.handler = { request in request.httpMethod == "GET" ? .init(200, ruleJSON) : .init(202) }
        let client = try makeClient(transport: transport)

        let rule = try await client.assignmentRule(appUUID: "3d958f38-246e-4854-a306-189d941ab073")
        #expect(rule.assignments.first?.name == "G")
        try await client.updateAssignmentRule(appUUID: "3d958f38-246e-4854-a306-189d941ab073", rule: rule)

        let get = try #require(transport.requests.first)
        let put = try #require(transport.requests.last)
        #expect(get.value(forHTTPHeaderField: "Accept") == "application/json;version=2")
        #expect(get.url?.path() == "/api/mam/apps/3d958f38-246e-4854-a306-189d941ab073/assignment-rules")
        #expect(put.httpMethod == "PUT")
        #expect(put.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONDecoder().decode(JSONValue.self, from: put.httpBody ?? Data())
        #expect(sent["assignments"]?.arrayValue?.first?["tunnel"]?["per_app_vpn_profile_uuid"] == .string("vpn-1"))
        #expect(sent["id"] == .int(7))
    }

    @Test("Empty assignment-rule responses become an empty rule")
    func emptyRule() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(204) }
        let client = try makeClient(transport: transport)
        #expect(try await client.assignmentRule(appUUID: "abc").isEmpty)
    }

    @Test("Rejects identifiers that could alter the request path", arguments: ["../../system/admins", "a/b", "id?x=1", ""])
    func rejectsPathInjection(identifier: String) async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)
        await #expect(throws: UEMError.self) { _ = try await client.assignmentRule(appUUID: identifier) }
        #expect(transport.requests.isEmpty)
    }

    @Test("Retire and delete call the documented endpoints")
    func retireAndDelete() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(202) }
        let client = try makeClient(transport: transport)
        try await client.retireApp(id: 1001)
        try await client.deleteBlob(id: 77)
        #expect(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "POST /api/mam/apps/internal/1001/retire",
            "DELETE /api/mam/blobs/blob/77"
        ])
    }

    @Test("Refuses plain HTTP servers")
    func refusesHTTP() {
        var profile = TestSupport.server()
        profile.apiURL = "http://uem.example.mil"
        #expect(throws: UEMError.self) {
            _ = try UEMClient(server: profile, secrets: ServerSecrets(), transport: MockTransport())
        }
    }

    @Test("Form encoding escapes reserved characters")
    func formEncoding() {
        let body = UEMClient.formEncoded([("k", "a b&c=d+e/é")])
        #expect(String(decoding: body, as: UTF8.self) == "k=a%20b%26c%3Dd%2Be%2F%C3%A9")
    }

    @Test("Error descriptions never include credentials")
    func errorsDoNotLeakSecrets() async throws {
        let transport = MockTransport()
        transport.handler = { _ in .init(401) }
        let client = try makeClient(transport: transport)
        do {
            _ = try await client.testConnection()
            Issue.record("Expected failure")
        } catch {
            let text = error.localizedDescription
            #expect(!text.contains("p@ss:word"))
            #expect(!text.contains("TENANT-KEY"))
            #expect(text.contains("401"))
        }
    }
}
