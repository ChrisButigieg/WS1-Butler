import Foundation
import Observation
import os

nonisolated enum LogLevel: String, Sendable, CaseIterable {
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERR"
}

nonisolated struct LogEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let source: String
    let message: String

    var formatted: String {
        "\(date.formatted(.iso8601)) [\(level.rawValue)] [\(source)] \(message)"
    }
}

/// In-memory operational log shown in the UI. Never record credentials or tokens here.
@Observable
final class ActivityLog {
    private(set) var entries: [LogEntry] = []
    private let capacity: Int
    private let logger = Logger(subsystem: "mil.afrc.ws1butler", category: "deployment")

    init(capacity: Int = 5_000) {
        self.capacity = capacity
    }

    func record(_ level: LogLevel, _ message: String, source: String = "SYSTEM") {
        entries.append(LogEntry(date: Date(), level: level, source: source, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        switch level {
        case .error: logger.error("[\(source, privacy: .public)] \(message, privacy: .private)")
        case .warning: logger.warning("[\(source, privacy: .public)] \(message, privacy: .private)")
        default: logger.info("[\(source, privacy: .public)] \(message, privacy: .private)")
        }
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        entries.map(\.formatted).joined(separator: "\n")
    }
}
