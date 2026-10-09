import SwiftUI
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// iOS App Store Package. Declared in Info.plist as an imported type.
    static let ipa = UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip)
}

/// Drag-and-drop payload for `.ipa` files.
///
/// The system deletes dropped files when the import closure returns, so the file is
/// copied synchronously into the staging inbox here; `IPAStager` then moves it.
struct IPADropFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .ipa) { received in
            let inbox = IPAStager.inboxRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let name = IPAStager.sanitizedFileName(received.file.lastPathComponent)
            let destination = inbox.appending(path: name)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return IPADropFile(url: destination)
        }
    }
}
