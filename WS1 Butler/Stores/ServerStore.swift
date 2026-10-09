import Foundation
import Observation

/// Persists server profiles (non-secret JSON in Application Support) and their
/// credentials (Keychain).
@Observable
final class ServerStore {
    private(set) var servers: [ServerProfile] = []
    var lastError: String?

    private let fileURL: URL?
    private let secretStore: SecretStore

    /// - Parameter fileURL: Where profiles are saved. `nil` keeps them in memory only.
    init(fileURL: URL?, secretStore: SecretStore) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        load()
    }

    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "WS1Butler", directoryHint: .isDirectory).appending(path: "servers.json")
    }

    var enabledServers: [ServerProfile] { servers.filter(\.isEnabled) }

    func server(id: UUID) -> ServerProfile? { servers.first { $0.id == id } }

    func secrets(for id: UUID) -> ServerSecrets {
        do {
            return try secretStore.secrets(for: id)
        } catch {
            lastError = error.localizedDescription
            return ServerSecrets()
        }
    }

    /// Whether the profile and its stored credentials pass validation (cached to avoid
    /// a Keychain read on every view update).
    func isConfigured(_ server: ServerProfile) -> Bool {
        configuredServerIDs.contains(server.id)
    }

    private(set) var configuredServerIDs: Set<UUID> = []

    private func refreshConfiguration() {
        configuredServerIDs = Set(servers.filter {
            ServerValidator.validate($0, secrets: secrets(for: $0.id)).isEmpty
        }.map(\.id))
    }

    /// Inserts or updates a profile and its credentials.
    func save(_ profile: ServerProfile, secrets: ServerSecrets) throws {
        try secretStore.save(secrets, for: profile.id)
        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[index] = profile
        } else {
            servers.append(profile)
        }
        refreshConfiguration()
        try persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].isEnabled = enabled
        try? persist()
    }

    func delete(id: UUID) throws {
        try secretStore.delete(for: id)
        servers.removeAll { $0.id == id }
        configuredServerIDs.remove(id)
        try persist()
    }

    /// Creates blank DEV / TEST / PROD profiles to fill in.
    func createStandardEnvironments() {
        let templates: [(String, ServerEnvironment)] = [("Development", .development), ("Test", .test), ("Production", .production)]
        for (name, environment) in templates where !servers.contains(where: { $0.environment == environment }) {
            var profile = ServerProfile()
            profile.name = name
            profile.environment = environment
            profile.isEnabled = false
            servers.append(profile)
        }
        try? persist()
    }

    // MARK: Persistence

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            servers = try JSONDecoder().decode([ServerProfile].self, from: data)
            refreshConfiguration()
        } catch {
            lastError = "Could not load saved servers: \(error.localizedDescription)"
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(servers)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }
}
