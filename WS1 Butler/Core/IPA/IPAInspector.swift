import Foundation

/// Metadata extracted from an IPA's `Payload/<App>.app/Info.plist`.
nonisolated struct IPAMetadata: Hashable, Sendable {
    var bundleIdentifier: String
    var shortVersion: String
    var buildVersion: String
    var displayName: String
    var minimumOSVersion: String?
    var deviceFamilies: [Int]
    var fileSize: UInt64
    /// PNG/CgBI icon data, when the IPA contains a flat app icon file.
    var iconData: Data?
}

nonisolated enum IPAError: LocalizedError, Equatable, Sendable {
    case wrongExtension
    case missingInfoPlist
    case unreadableInfoPlist
    case missingBundleIdentifier
    case zip(ZipError)

    var errorDescription: String? {
        switch self {
        case .wrongExtension: "Only .ipa files can be deployed."
        case .missingInfoPlist: "The IPA does not contain Payload/<App>.app/Info.plist."
        case .unreadableInfoPlist: "The app's Info.plist could not be read."
        case .missingBundleIdentifier: "The app's Info.plist has no CFBundleIdentifier."
        case .zip(let error): error.errorDescription
        }
    }
}

nonisolated enum IPAInspector {
    /// Reads metadata from an IPA on disk without unpacking it.
    static func inspect(url: URL) throws(IPAError) -> IPAMetadata {
        guard url.pathExtension.lowercased() == "ipa" else { throw .wrongExtension }

        let reader: ZipArchiveReader
        do {
            reader = try ZipArchiveReader(url: url)
        } catch let error as ZipError {
            throw .zip(error)
        } catch {
            throw .zip(.notAZipArchive)
        }

        // Exactly one level deep: Payload/<Name>.app/Info.plist (ignore nested frameworks/extensions).
        guard let plistEntry = reader.entries.first(where: { isMainInfoPlist($0.path) }) else {
            throw .missingInfoPlist
        }

        let plist: [String: Any]
        do {
            let data = try reader.extract(plistEntry)
            guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw IPAError.unreadableInfoPlist
            }
            plist = dict
        } catch let error as ZipError {
            throw .zip(error)
        } catch {
            throw .unreadableInfoPlist
        }

        guard let bundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespaces),
              !bundleID.isEmpty
        else { throw .missingBundleIdentifier }

        let shortVersion = plist["CFBundleShortVersionString"] as? String ?? "0"
        let build = plist["CFBundleVersion"] as? String ?? shortVersion
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let families = (plist["UIDeviceFamily"] as? [Any])?.compactMap { value -> Int? in
            if let int = value as? Int { return int }
            if let string = value as? String { return Int(string) }
            return nil
        } ?? []

        let appDirectory = (plistEntry.path as NSString).deletingLastPathComponent
        let icon = try? extractIcon(reader: reader, appDirectory: appDirectory)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0

        return IPAMetadata(
            bundleIdentifier: bundleID,
            shortVersion: shortVersion,
            buildVersion: build,
            displayName: name,
            minimumOSVersion: plist["MinimumOSVersion"] as? String,
            deviceFamilies: families,
            fileSize: size,
            iconData: icon
        )
    }

    static func isMainInfoPlist(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts[0] == "Payload"
            && parts[1].hasSuffix(".app")
            && parts[2] == "Info.plist"
    }

    /// Picks the largest flat `AppIcon*.png` in the app bundle root (best effort).
    private static func extractIcon(reader: ZipArchiveReader, appDirectory: String) throws -> Data? {
        let prefix = appDirectory + "/"
        let candidates = reader.entries.filter { entry in
            guard entry.path.hasPrefix(prefix) else { return false }
            let name = String(entry.path.dropFirst(prefix.count))
            return !name.contains("/") && name.hasPrefix("AppIcon") && name.hasSuffix(".png")
                && entry.uncompressedSize < 2 * 1024 * 1024
        }
        guard let best = candidates.max(by: { $0.uncompressedSize < $1.uncompressedSize }) else { return nil }
        return try reader.extract(best)
    }
}
