import Foundation

nonisolated struct StagedIPA: Sendable {
    let url: URL
    let fileName: String
    let metadata: IPAMetadata
}

/// Copies user-selected IPAs into the app's private staging area and inspects them.
///
/// Copying means the deployment never depends on a security-scoped URL staying valid
/// (important on iPad, where Files-app access is revoked when the picker's scope ends).
nonisolated enum IPAStager {
    static var stagingRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "Staging", directoryHint: .isDirectory)
    }

    /// Drag-and-drop copies land here first; they are moved (not copied again) when staged.
    static var inboxRoot: URL {
        stagingRoot.appending(path: "Inbox", directoryHint: .isDirectory)
    }

    @concurrent
    static func stage(_ source: URL) async throws -> StagedIPA {
        guard source.pathExtension.lowercased() == "ipa" else { throw IPAError.wrongExtension }

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let fileName = sanitizedFileName(source.lastPathComponent)
        let folder = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: fileName)
        let isInInbox = source.standardizedFileURL.path.hasPrefix(inboxRoot.standardizedFileURL.path)

        do {
            if isInInbox {
                try FileManager.default.moveItem(at: source, to: destination)
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            #if os(iOS)
            try? (destination as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
            #endif
            let metadata = try IPAInspector.inspect(url: destination)
            return StagedIPA(url: destination, fileName: fileName, metadata: metadata)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func discard(_ stagedURL: URL) {
        let folder = stagedURL.deletingLastPathComponent()
        // Only ever delete inside our own staging area.
        guard folder.standardizedFileURL.path.hasPrefix(stagingRoot.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes anything left over from a previous session.
    static func purgeAll() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    /// Keeps the name readable but strips path separators and control characters.
    static func sanitizedFileName(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { !disallowed.contains($0) }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty || cleaned.lowercased() == "ipa" { cleaned = "app.ipa" }
        if !cleaned.lowercased().hasSuffix(".ipa") { cleaned += ".ipa" }
        return String(cleaned.suffix(200))
    }
}
