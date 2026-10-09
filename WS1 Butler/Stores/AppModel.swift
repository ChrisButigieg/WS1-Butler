import Foundation
import Observation

/// Root dependency container shared through the SwiftUI environment.
@Observable
final class AppModel {
    let log: ActivityLog
    let servers: ServerStore
    let coordinator: DeploymentCoordinator
    let isDemoMode: Bool

    private let transport: HTTPTransport

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let isUITesting = arguments.contains("-uitesting")
        #if DEBUG
        let demo = arguments.contains("-demo")
        #else
        let demo = false
        #endif
        isDemoMode = demo

        let log = ActivityLog()
        let transport = URLSessionTransport()
        let ephemeral = isUITesting || demo
        let servers = ServerStore(
            fileURL: ephemeral ? nil : ServerStore.defaultFileURL,
            secretStore: ephemeral ? InMemorySecretStore() : KeychainSecretStore()
        )
        self.log = log
        self.transport = transport
        self.servers = servers

        #if DEBUG
        var mocks: [UUID: MockUEMService] = [:]
        #endif
        let engine = DeploymentEngine(log: log) { profile in
            #if DEBUG
            if demo {
                if let mock = mocks[profile.id] { return mock }
                let mock = MockUEMService.populated(bundleID: "mil.afrc.missionplanner")
                mock.latency = .milliseconds(350)
                mocks[profile.id] = mock
                return mock
            }
            #endif
            return try UEMClient(server: profile, secrets: servers.secrets(for: profile.id), transport: transport)
        }
        coordinator = DeploymentCoordinator(
            engine: engine,
            log: log,
            defaults: ephemeral ? UserDefaults(suiteName: "ws1butler.ephemeral.\(UUID().uuidString)") : .standard
        )

        IPAStager.purgeAll()
        log.record(.info, "WS1 Butler online", source: "SYSTEM")

        #if DEBUG
        if demo { seedDemo() }
        #endif
    }

    /// A fresh client for one-off operations such as "Test Connection".
    func makeClient(for profile: ServerProfile, secrets: ServerSecrets) throws -> UEMService {
        #if DEBUG
        if isDemoMode { return MockUEMService.populated(bundleID: "mil.afrc.missionplanner") }
        #endif
        return try UEMClient(server: profile, secrets: secrets, transport: transport)
    }

    #if DEBUG
    private func seedDemo() {
        let environments: [(String, ServerEnvironment, String)] = [
            ("Development", .development, "https://dev-uem.example.mil"),
            ("Test", .test, "https://test-uem.example.mil"),
            ("Production", .production, "https://uem.example.mil")
        ]
        for (name, env, url) in environments {
            var profile = ServerProfile()
            profile.name = name
            profile.environment = env
            profile.apiURL = url
            profile.organizationGroupID = 570
            profile.organizationGroupName = "AFRC Mobility"
            profile.authMethod = env == .production ? .basic : .oauth
            profile.username = "api-admin"
            profile.clientID = "ws1butler-client"
            try? servers.save(profile, secrets: ServerSecrets(password: "demo", tenantCode: "demo-key", clientSecret: "demo"))
        }
        coordinator.selectedServerIDs = Set(servers.servers.map(\.id))

        let folder = IPAStager.stagingRoot.appending(path: "demo", directoryHint: .isDirectory)
        let url = folder.appending(path: "MissionPlanner-1.1.0.ipa")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ZipFixtureWriter.ipa(bundleID: "mil.afrc.missionplanner").write(to: url)
            let metadata = try IPAInspector.inspect(url: url)
            coordinator.enqueue(DeploymentQueueItem(stagedFileURL: url, fileName: url.lastPathComponent, metadata: metadata))
        } catch {
            log.record(.error, "Demo seed failed: \(error.localizedDescription)")
        }
    }
    #endif
}
