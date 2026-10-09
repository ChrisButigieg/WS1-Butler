import Foundation
import Testing
@testable import WS1Butler

/// Shared helpers for the unit test suites.
enum TestSupport {
    /// Creates a unique temporary directory that is removed when the returned closure is called.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "WS1ButlerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, named name: String) throws -> URL {
        let url = try temporaryDirectory().appending(path: name)
        try data.write(to: url)
        return url
    }

    static func server(_ name: String = "Dev", environment: ServerEnvironment = .development,
                       auth: AuthMethod = .basic) -> ServerProfile {
        var profile = ServerProfile()
        profile.name = name
        profile.environment = environment
        profile.apiURL = "https://as1234.awmdm.com"
        profile.organizationGroupID = 570
        profile.authMethod = auth
        profile.username = "api-admin"
        profile.clientID = "client-123"
        profile.oauthRegion = .northAmerica
        return profile
    }

    static func queueItem(bundleID: String = "mil.afrc.missionplanner", version: String = "1.1.0",
                          families: [Int] = [2]) -> DeploymentQueueItem {
        let metadata = IPAMetadata(bundleIdentifier: bundleID, shortVersion: version, buildVersion: "42",
                                   displayName: "Mission Planner", minimumOSVersion: "17.0",
                                   deviceFamilies: families, fileSize: 1_024)
        return DeploymentQueueItem(stagedFileURL: URL(filePath: "/tmp/MissionPlanner.ipa"),
                                   fileName: "MissionPlanner.ipa", metadata: metadata)
    }

    /// Polls until `condition` is true (or fails the test after ~5 seconds).
    static func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
    }
}

@Suite("ZIP archive reader")
struct ZipArchiveReaderTests {
    @Test("Reads stored and deflated entries", arguments: [false, true])
    func readsEntries(deflate: Bool) throws {
        let payload = Data(String(repeating: "WS1 Butler ", count: 400).utf8)
        let archive = ZipFixtureWriter.archive([
            .init(path: "a.txt", data: payload, deflate: deflate),
            .init(path: "dir/b.bin", data: Data([1, 2, 3]), deflate: false)
        ])
        let url = try TestSupport.write(archive, named: "test.zip")
        let reader = try ZipArchiveReader(url: url)

        #expect(reader.entries.map(\.path) == ["a.txt", "dir/b.bin"])
        let first = try #require(reader.entries.first)
        #expect(first.compressionMethod == (deflate ? 8 : 0))
        #expect(try reader.extract(first) == payload)
        #expect(try reader.extract(reader.entries[1]) == Data([1, 2, 3]))
    }

    @Test("Reads ZIP64 archives")
    func readsZip64() throws {
        let payload = Data("zip64 payload".utf8)
        let archive = ZipFixtureWriter.archive([.init(path: "big.txt", data: payload, deflate: true)], zip64: true)
        let url = try TestSupport.write(archive, named: "zip64.zip")
        let reader = try ZipArchiveReader(url: url)
        let entry = try #require(reader.entries.first)
        #expect(entry.path == "big.txt")
        #expect(entry.uncompressedSize == UInt64(payload.count))
        #expect(try reader.extract(entry) == payload)
    }

    @Test("Rejects non-ZIP data")
    func rejectsGarbage() throws {
        let url = try TestSupport.write(Data(repeating: 0x41, count: 4_096), named: "junk.zip")
        #expect(throws: ZipError.notAZipArchive) { try ZipArchiveReader(url: url) }

        let tiny = try TestSupport.write(Data([0x50, 0x4b]), named: "tiny.zip")
        #expect(throws: ZipError.notAZipArchive) { try ZipArchiveReader(url: tiny) }
    }

    @Test("Rejects entries above the extraction limit")
    func enforcesSizeLimit() throws {
        let archive = ZipFixtureWriter.archive([.init(path: "x", data: Data(count: 2_048))])
        let reader = try ZipArchiveReader(url: try TestSupport.write(archive, named: "limit.zip"))
        let entry = try #require(reader.entries.first)
        #expect(throws: ZipError.entryTooLarge(2_048)) { try reader.extract(entry, maximumSize: 1_024) }
    }

    @Test("Truncated or corrupted archives throw instead of crashing")
    func fuzzCorruption() throws {
        let original = ZipFixtureWriter.ipa(bundleID: "mil.afrc.fuzz")
        var generator = SystemRandomNumberGenerator()
        let directory = try TestSupport.temporaryDirectory()

        for iteration in 0..<300 {
            var data = original
            switch iteration % 3 {
            case 0:
                data = data.prefix(Int.random(in: 0..<data.count, using: &generator))
            case 1:
                for _ in 0..<8 {
                    let index = Int.random(in: 0..<data.count, using: &generator)
                    data[index] = UInt8.random(in: 0...255, using: &generator)
                }
            default:
                // Corrupt the tail where the central directory lives.
                for offset in 1...min(40, data.count) where Bool.random(using: &generator) {
                    data[data.count - offset] = UInt8.random(in: 0...255, using: &generator)
                }
            }
            let url = directory.appending(path: "fuzz-\(iteration).ipa")
            try data.write(to: url)
            // Either outcome is fine; the requirement is no crash and no hang.
            _ = try? IPAInspector.inspect(url: url)
        }
    }
}

@Suite("IPA inspector")
struct IPAInspectorTests {
    @Test("Extracts bundle metadata from the main Info.plist", arguments: [true, false])
    func extractsMetadata(deflate: Bool) throws {
        let data = ZipFixtureWriter.ipa(bundleID: "mil.afrc.missionplanner", version: "2.3.1", build: "118",
                                        name: "Mission Planner", deviceFamilies: [1, 2], deflate: deflate)
        let url = try TestSupport.write(data, named: "MissionPlanner.ipa")
        let metadata = try IPAInspector.inspect(url: url)

        #expect(metadata.bundleIdentifier == "mil.afrc.missionplanner")
        #expect(metadata.shortVersion == "2.3.1")
        #expect(metadata.buildVersion == "118")
        #expect(metadata.displayName == "Mission Planner")
        #expect(metadata.minimumOSVersion == "17.0")
        #expect(metadata.deviceFamilies == [1, 2])
        #expect(metadata.fileSize == UInt64(data.count))
    }

    @Test("Handles ZIP64 IPAs")
    func zip64IPA() throws {
        let url = try TestSupport.write(ZipFixtureWriter.ipa(bundleID: "mil.afrc.z64", zip64: true), named: "z.ipa")
        #expect(try IPAInspector.inspect(url: url).bundleIdentifier == "mil.afrc.z64")
    }

    @Test("Fails when CFBundleIdentifier is missing")
    func missingBundleID() throws {
        let url = try TestSupport.write(ZipFixtureWriter.ipa(bundleID: nil), named: "nobundle.ipa")
        #expect(throws: IPAError.missingBundleIdentifier) { try IPAInspector.inspect(url: url) }
    }

    @Test("Fails when there is no app Info.plist")
    func missingPlist() throws {
        let archive = ZipFixtureWriter.archive([.init(path: "Payload/App.app/App", data: Data([0]))])
        let url = try TestSupport.write(archive, named: "noplist.ipa")
        #expect(throws: IPAError.missingInfoPlist) { try IPAInspector.inspect(url: url) }
    }

    @Test("Rejects files that are not .ipa")
    func wrongExtension() throws {
        let url = try TestSupport.write(ZipFixtureWriter.ipa(bundleID: "x"), named: "app.zip")
        #expect(throws: IPAError.wrongExtension) { try IPAInspector.inspect(url: url) }
    }

    @Test("Only matches Payload/<App>.app/Info.plist", arguments: [
        ("Payload/App.app/Info.plist", true),
        ("Payload/My App.app/Info.plist", true),
        ("Payload/App.app/Frameworks/X.framework/Info.plist", false),
        ("Payload/App.app/PlugIns/Ext.appex/Info.plist", false),
        ("Info.plist", false),
        ("Payload/App/Info.plist", false),
        ("Other/App.app/Info.plist", false)
    ])
    func mainInfoPlistMatching(path: String, expected: Bool) {
        #expect(IPAInspector.isMainInfoPlist(path) == expected)
    }
}
