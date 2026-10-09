import Foundation
import Testing
@testable import WS1Butler

@Suite("Server store")
struct ServerStoreTests {
    @Test("Persists profiles to disk but keeps secrets out of the file")
    func persistsWithoutSecrets() throws {
        let file = try TestSupport.temporaryDirectory().appending(path: "servers.json")
        let secrets = InMemorySecretStore()
        let store = ServerStore(fileURL: file, secretStore: secrets)
        let profile = TestSupport.server("Prod", environment: .production)
        try store.save(profile, secrets: ServerSecrets(password: "TopSecretPassword!", tenantCode: "TENANT-API-KEY"))

        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("Prod"))
        #expect(!contents.contains("TopSecretPassword!"))
        #expect(!contents.contains("TENANT-API-KEY"))

        let reloaded = ServerStore(fileURL: file, secretStore: secrets)
        #expect(reloaded.servers == [profile])
        #expect(reloaded.isConfigured(profile))
        #expect(reloaded.secrets(for: profile.id).password == "TopSecretPassword!")
    }

    @Test("Tracks configuration state and deletion")
    func configurationState() throws {
        let store = ServerStore(fileURL: nil, secretStore: InMemorySecretStore())
        let profile = TestSupport.server()
        try store.save(profile, secrets: ServerSecrets())
        #expect(!store.isConfigured(profile))
        try store.save(profile, secrets: ServerSecrets(password: "p", tenantCode: "k"))
        #expect(store.isConfigured(profile))
        #expect(store.servers.count == 1)

        store.setEnabled(false, for: profile.id)
        #expect(store.enabledServers.isEmpty)

        try store.delete(id: profile.id)
        #expect(store.servers.isEmpty)
        #expect(!store.isConfigured(profile))
        #expect(store.secrets(for: profile.id).isEmpty)
    }

    @Test("Quick setup creates DEV, TEST and PROD once")
    func quickSetup() {
        let store = ServerStore(fileURL: nil, secretStore: InMemorySecretStore())
        store.createStandardEnvironments()
        store.createStandardEnvironments()
        #expect(store.servers.map(\.environment) == [.development, .test, .production])
        #expect(store.servers.allSatisfy { !$0.isEnabled })
    }

    @Test("Supports more than three servers")
    func manyServers() throws {
        let store = ServerStore(fileURL: nil, secretStore: InMemorySecretStore())
        for index in 0..<6 {
            try store.save(TestSupport.server("Server \(index)"), secrets: ServerSecrets(password: "p", tenantCode: "k"))
        }
        #expect(store.servers.count == 6)
        #expect(store.configuredServerIDs.count == 6)
    }

    @Test("A corrupted profiles file does not crash")
    func corruptedFile() throws {
        let file = try TestSupport.temporaryDirectory().appending(path: "servers.json")
        try Data("{ not json".utf8).write(to: file)
        let store = ServerStore(fileURL: file, secretStore: InMemorySecretStore())
        #expect(store.servers.isEmpty)
        #expect(store.lastError != nil)
    }
}

@Suite("Keychain secret store", .serialized)
struct KeychainSecretStoreTests {
    @Test("Round-trips, updates, and deletes credentials")
    func roundTrip() throws {
        let store = KeychainSecretStore(service: "mil.afrc.ws1butler.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.delete(for: id) }

        #expect(try store.secrets(for: id).isEmpty)
        try store.save(ServerSecrets(password: "one", tenantCode: "key"), for: id)
        #expect(try store.secrets(for: id) == ServerSecrets(password: "one", tenantCode: "key"))
        try store.save(ServerSecrets(clientSecret: "two"), for: id)
        #expect(try store.secrets(for: id) == ServerSecrets(clientSecret: "two"))
        try store.delete(for: id)
        #expect(try store.secrets(for: id).isEmpty)
        // Deleting twice is harmless.
        try store.delete(for: id)
    }
}

@Suite("Activity log")
struct ActivityLogTests {
    @Test("Caps the number of retained entries")
    func capacity() {
        let log = ActivityLog(capacity: 10)
        for index in 0..<25 { log.record(.info, "entry \(index)") }
        #expect(log.entries.count == 10)
        #expect(log.entries.first?.message == "entry 15")
        #expect(log.exportText.split(separator: "\n").count == 10)
        log.clear()
        #expect(log.entries.isEmpty)
    }
}
