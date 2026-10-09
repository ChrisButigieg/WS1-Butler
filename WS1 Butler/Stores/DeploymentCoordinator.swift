import Foundation
import Observation

/// Owns the IPA queue and drives deployments.
///
/// One worker task runs per server, so every server (e.g. DEV, TEST, PROD) receives
/// uploads in parallel while each individual server processes the queue in order.
@Observable
final class DeploymentCoordinator {
    private(set) var queue: [DeploymentQueueItem] = []
    private(set) var importErrors: [String] = []
    private(set) var isImporting = false
    var options: DeploymentOptions {
        didSet { saveOptions() }
    }
    /// Servers the operator selected for the current/next launch.
    var selectedServerIDs: Set<UUID> = []

    private var workers: [UUID: Task<Void, Never>] = [:]
    private let engine: DeploymentEngine
    private let log: ActivityLog
    private let defaults: UserDefaults?
    private static let optionsKey = "deploymentOptions"

    init(engine: DeploymentEngine, log: ActivityLog, defaults: UserDefaults? = .standard) {
        self.engine = engine
        self.log = log
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.optionsKey),
           let saved = try? JSONDecoder().decode(DeploymentOptions.self, from: data) {
            options = saved
        } else {
            options = DeploymentOptions()
        }
    }

    var isRunning: Bool { !workers.isEmpty }
    var pendingReviewCount: Int {
        queue.reduce(0) { $0 + $1.targets.filter { $0.status == .awaitingReview }.count }
    }
    var unlaunchedItems: [DeploymentQueueItem] { queue.filter { !$0.hasLaunched } }

    // MARK: Queue management

    func importFiles(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        importErrors.removeAll()

        for url in urls {
            do {
                let staged = try await IPAStager.stage(url)
                if let duplicate = queue.first(where: {
                    $0.metadata.bundleIdentifier == staged.metadata.bundleIdentifier
                        && $0.metadata.shortVersion == staged.metadata.shortVersion
                        && $0.metadata.buildVersion == staged.metadata.buildVersion
                        && !$0.isFinished
                }) {
                    IPAStager.discard(staged.url)
                    importErrors.append("\(url.lastPathComponent): already queued as \(duplicate.fileName).")
                    continue
                }
                let item = DeploymentQueueItem(stagedFileURL: staged.url, fileName: staged.fileName, metadata: staged.metadata)
                queue.append(item)
                log.record(.info, "Queued \(staged.metadata.displayName) \(staged.metadata.shortVersion) [\(staged.metadata.bundleIdentifier)]", source: "QUEUE")
                if isRunning { attachTargets(to: item, servers: activeRunServers) }
            } catch {
                let message = "\(url.lastPathComponent): \(error.localizedDescription)"
                importErrors.append(message)
                log.record(.error, "Import failed — \(message)", source: "QUEUE")
            }
        }
    }

    /// Adds an already-staged item (used by tests and demo mode).
    func enqueue(_ item: DeploymentQueueItem) {
        queue.append(item)
    }

    func dismissImportErrors() {
        importErrors.removeAll()
    }

    func canRemove(_ item: DeploymentQueueItem) -> Bool { !item.isActive }

    func remove(_ item: DeploymentQueueItem) {
        guard canRemove(item) else { return }
        for target in item.targets where target.status == .queued {
            target.status = .cancelled
        }
        queue.removeAll { $0.id == item.id }
        IPAStager.discard(item.stagedFileURL)
    }

    func clearFinished() {
        for item in queue where item.isFinished {
            IPAStager.discard(item.stagedFileURL)
        }
        queue.removeAll { $0.isFinished }
    }

    // MARK: Execution

    private var activeRunServers: [ServerProfile] = []

    /// Launches deployment of every not-yet-launched item to the given servers.
    func launch(servers: [ServerProfile]) {
        guard !servers.isEmpty else { return }
        activeRunServers = servers
        for item in queue where !item.hasLaunched {
            attachTargets(to: item, servers: servers)
        }
        log.record(.info, "Launch: \(unlaunchedSummary()) → \(servers.map(\.displayName).joined(separator: ", "))", source: "COMMAND")
        for server in servers { ensureWorker(for: server.id) }
    }

    private func unlaunchedSummary() -> String {
        let count = queue.filter { $0.targets.contains { $0.status == .queued } }.count
        return "\(count) app(s)"
    }

    private func attachTargets(to item: DeploymentQueueItem, servers: [ServerProfile]) {
        for server in servers where item.target(for: server.id) == nil {
            item.targets.append(DeploymentTarget(server: server))
        }
    }

    func retry(_ target: DeploymentTarget) {
        guard target.status.isFinished else { return }
        target.reset()
        log.record(.info, "Retry requested", source: "\(target.server.environment.rawValue):\(target.server.displayName)")
        ensureWorker(for: target.server.id)
    }

    /// Aborts everything: running pipelines stop at the next step boundary and
    /// pending reviews resolve as "abort".
    func abortAll() {
        for item in queue {
            for target in item.targets {
                if target.status == .queued {
                    target.status = .cancelled
                    target.detail = "Aborted before start"
                }
                target.reviewGate?.resolve(.abort)
            }
        }
        for worker in workers.values { worker.cancel() }
        log.record(.warning, "Abort issued for all deployments", source: "COMMAND")
    }

    private func ensureWorker(for serverID: UUID) {
        guard workers[serverID] == nil else { return }
        workers[serverID] = Task { [weak self] in
            while let self, !Task.isCancelled, let next = self.nextQueued(for: serverID) {
                await self.engine.run(item: next.item, target: next.target, options: self.options)
            }
            self?.workers[serverID] = nil
        }
    }

    private func nextQueued(for serverID: UUID) -> (item: DeploymentQueueItem, target: DeploymentTarget)? {
        for item in queue {
            if let target = item.target(for: serverID), target.status == .queued {
                return (item, target)
            }
        }
        return nil
    }

    /// Waits until all workers finish (used by tests).
    func waitUntilIdle() async {
        while let worker = workers.values.first {
            await worker.value
        }
    }

    private func saveOptions() {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults?.set(data, forKey: Self.optionsKey)
    }
}
