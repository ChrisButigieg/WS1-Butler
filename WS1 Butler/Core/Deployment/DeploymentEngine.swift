import Foundation

/// Runs the deployment pipeline for a single (IPA, server) pair:
///
/// 1. Authenticate and confirm the Organization Group.
/// 2. Locate the currently active internal app with the same bundle ID.
/// 3. Snapshot that version's assignment rule (smart groups, delivery, app config).
/// 4. Upload the IPA as a blob.
/// 5. Create the new version via `begininstall` with `CarryOverAssignments`.
/// 6. Verify the carried-over rule against the snapshot (optionally restoring it).
/// 7. Optionally pause for operator review / app config edits.
/// 8. Publish the assignment rule.
/// 9. Retire the previous version.
final class DeploymentEngine {
    typealias ServiceFactory = (ServerProfile) throws -> UEMService

    private let makeService: ServiceFactory
    private let log: ActivityLog

    init(log: ActivityLog, makeService: @escaping ServiceFactory) {
        self.log = log
        self.makeService = makeService
    }

    /// Ends the pipeline early without counting as a failure.
    private struct Stop: Error {
        let status: TargetStatus
    }

    private enum StepOutcome {
        case done(String)
        case skipped(String)
    }

    func run(item: DeploymentQueueItem, target: DeploymentTarget, options: DeploymentOptions) async {
        guard target.status == .queued else { return }
        target.status = .running
        target.startedAt = Date()
        let source = "\(target.server.environment.rawValue):\(target.server.displayName)"
        let ipa = item.metadata
        log.record(.info, "Starting \(ipa.displayName) \(ipa.shortVersion) (\(ipa.buildVersion))", source: source)

        do {
            let service = try makeService(target.server)
            try await runSteps(item: item, target: target, service: service, options: options, source: source)

            if target.warnings.isEmpty {
                target.status = .succeeded
                target.detail = "Deployment complete"
                log.record(.success, "\(ipa.displayName) \(ipa.shortVersion) deployed", source: source)
            } else {
                let summary = target.warnings.joined(separator: " • ")
                target.status = .completedWithWarnings(summary)
                target.detail = "Complete with warnings"
                log.record(.warning, "\(ipa.displayName) deployed with warnings: \(summary)", source: source)
            }
        } catch let stop as Stop {
            target.status = stop.status
            switch stop.status {
            case .skipped(let reason):
                target.detail = reason
                log.record(.warning, "Skipped: \(reason)", source: source)
            case .cancelled:
                target.detail = "Aborted by operator"
                log.record(.warning, "Aborted by operator", source: source)
            default:
                break
            }
        } catch is CancellationError {
            markActiveStep(target, as: .failed)
            target.status = .cancelled
            target.detail = "Aborted"
            log.record(.warning, "Deployment aborted", source: source)
        } catch {
            markActiveStep(target, as: .failed)
            let message = error.localizedDescription
            target.status = .failed(message)
            target.detail = message
            let stepName = target.currentStep?.title ?? "Pipeline"
            log.record(.error, "\(stepName) failed: \(message)", source: source)
        }
        target.reviewGate = nil
        target.finishedAt = Date()
    }

    // MARK: - Steps

    private func runSteps(item: DeploymentQueueItem, target: DeploymentTarget, service: UEMService,
                          options: DeploymentOptions, source: String) async throws {
        let ipa = item.metadata
        let server = target.server

        try await step(.authenticate, target, source) {
            let group = try await service.testConnection()
            return .done("Connected to OG \(group.name ?? String(server.organizationGroupID))")
        }

        try await step(.locate, target, source) {
            let apps = try await service.findInternalApps(bundleID: ipa.bundleIdentifier)
            let active = apps.filter(\.isActive).sorted {
                VersionComparator.compare($0.displayVersion, $1.displayVersion) == .orderedDescending
            }
            if let previous = active.first {
                target.previousApp = previous
                if VersionComparator.compare(ipa.shortVersion, previous.displayVersion) != .orderedDescending {
                    target.warnings.append("IPA version \(ipa.shortVersion) is not newer than deployed \(previous.displayVersion)")
                }
                return .done("Found \(previous.applicationName ?? ipa.displayName) v\(previous.displayVersion)")
            }
            guard options.allowNewApplications else {
                throw Stop(status: .skipped("No active version of \(ipa.bundleIdentifier) exists on this server. Enable “Create new apps” to upload it as a new application."))
            }
            target.warnings.append("Uploaded as a new application — assign it in the console")
            return .done("No existing version — creating new application")
        }

        try await step(.snapshot, target, source) {
            guard let uuid = target.previousApp?.uuid else { return .skipped("Nothing to snapshot") }
            let rule = try await service.assignmentRule(appUUID: uuid)
            target.expectedRule = rule
            target.smartGroupNames = (try? await service.smartGroupNames()) ?? [:]
            let configCount = rule.assignments.reduce(0) { $0 + $1.configuration.count }
            return .done("\(rule.assignments.count) assignment group(s), \(configCount) app config key(s)")
        }

        var blobID: Int?
        try await step(.upload, target, source) {
            let id = try await service.uploadBlob(fileURL: item.stagedFileURL, fileName: item.fileName) { fraction in
                Task { @MainActor in target.uploadProgress = fraction }
            }
            blobID = id
            target.uploadProgress = 1
            return .done("Uploaded \(ByteCountFormatter.string(fromByteCount: Int64(ipa.fileSize), countStyle: .file))")
        }

        try await step(.create, target, source) {
            guard let blobID else { throw UEMError.unexpectedResponse("missing blob ID") }
            let request = makeBeginInstallRequest(blobID: blobID, item: item, previous: target.previousApp, server: server)
            let created: UEMApplication
            do {
                created = try await service.beginInstall(request)
            } catch {
                // Do not leave an orphaned multi-hundred-megabyte blob behind.
                try? await service.deleteBlob(id: blobID)
                throw error
            }
            target.newApp = try await resolveNewApp(created, service: service, ipa: ipa, previous: target.previousApp)
            return .done("Created version \(target.newApp?.displayVersion ?? ipa.shortVersion) (ID \(target.newApp?.id ?? 0))")
        }

        try await step(.validate, target, source) {
            guard let newUUID = target.newApp?.uuid else { throw UEMError.unexpectedResponse("new app has no UUID") }
            let carried = try await service.assignmentRule(appUUID: newUUID)
            target.carriedRule = carried
            target.workingRule = carried

            guard let expected = target.expectedRule else { return .skipped("No previous version to compare") }
            target.discrepancies = AssignmentComparator.compare(expected: expected, actual: carried)
            if target.discrepancies.isEmpty {
                return .done("Assignments and app config match previous version")
            }
            if options.restoreAssignmentsIfMissing, !expected.isEmpty {
                target.workingRule = Self.mergedForRestore(expected: expected, carried: carried)
                target.restoredFromPrevious = true
                return .done("\(target.discrepancies.count) discrepancy(ies) — restored previous assignments")
            }
            target.warnings.append("\(target.discrepancies.count) assignment discrepancy(ies) not corrected")
            return .done("\(target.discrepancies.count) discrepancy(ies) detected")
        }

        var publishApproved = true
        try await step(.review, target, source) {
            guard options.reviewBeforePublish else { return .skipped("Auto-publish enabled") }
            let gate = ReviewGate()
            target.reviewGate = gate
            target.status = .awaitingReview
            target.detail = "Awaiting operator review"
            log.record(.info, "Awaiting operator review", source: source)
            let decision = await gate.wait()
            target.reviewGate = nil
            target.status = .running
            switch decision {
            case .publish(let rule):
                target.workingRule = rule
                return .done("Approved by operator")
            case .skipPublish:
                publishApproved = false
                target.warnings.append("Publish skipped by operator — previous version left active")
                return .done("Operator chose not to publish")
            case .abort:
                throw Stop(status: .cancelled)
            }
        }

        var published = false
        try await step(.publish, target, source) {
            guard publishApproved else { return .skipped("Skipped by operator") }
            guard let newUUID = target.newApp?.uuid, let rule = target.workingRule, !rule.isEmpty else {
                if target.previousApp != nil {
                    target.warnings.append("New version has no assignments")
                }
                return .skipped("No assignments to publish")
            }
            try await service.updateAssignmentRule(appUUID: newUUID, rule: rule)
            published = true
            return .done("Published \(rule.assignments.count) assignment group(s)")
        }

        try await step(.retire, target, source) {
            guard options.retirePreviousVersion else { return .skipped("Retire disabled") }
            guard let previousID = target.previousApp?.id else { return .skipped("No previous version") }
            guard published || target.expectedRule?.isEmpty == true else {
                return .skipped("New version not published — previous version kept active")
            }
            try await service.retireApp(id: previousID)
            return .done("Retired v\(target.previousApp?.displayVersion ?? "?") (ID \(previousID))")
        }
    }

    private func step(_ step: DeploymentStep, _ target: DeploymentTarget, _ source: String,
                      _ body: () async throws -> StepOutcome) async throws {
        try Task.checkCancellation()
        target.currentStep = step
        target.stepStates[step] = .active
        target.detail = step.title + "…"
        let outcome = try await body()
        switch outcome {
        case .done(let message):
            target.stepStates[step] = .done
            target.detail = message
            log.record(.info, "\(step.code): \(message)", source: source)
        case .skipped(let message):
            target.stepStates[step] = .skipped
            target.detail = message
            log.record(.info, "\(step.code) skipped: \(message)", source: source)
        }
    }

    private func markActiveStep(_ target: DeploymentTarget, as state: StepState) {
        if let step = target.currentStep, target.state(of: step) == .active {
            target.stepStates[step] = state
        }
    }

    // MARK: - Helpers

    func makeBeginInstallRequest(blobID: Int, item: DeploymentQueueItem, previous: UEMApplication?,
                                 server: ServerProfile) -> BeginInstallRequest {
        let ipa = item.metadata
        let previousModels = previous?.supportedModels?.model ?? []
        let models = previousModels.isEmpty
            ? BeginInstallRequest.supportedModels(forDeviceFamilies: ipa.deviceFamilies)
            : UEMApplication.SupportedModels(model: previousModels)
        let pushMode = previous?.pushMode?.lowercased() == "auto" ? "Auto" : "OnDemand"
        let name = previous?.applicationName?.isEmpty == false ? (previous?.applicationName ?? ipa.displayName) : ipa.displayName

        return BeginInstallRequest(
            blobID: blobID,
            applicationName: name,
            supportedModels: models,
            pushMode: pushMode,
            locationGroupID: server.organizationGroupID,
            fileName: item.fileName,
            description: previous?.description,
            carryOverAssignments: true
        )
    }

    /// `begininstall` normally returns the new app's ID and UUID; if not, look it up.
    private func resolveNewApp(_ created: UEMApplication, service: UEMService, ipa: IPAMetadata,
                               previous: UEMApplication?) async throws -> UEMApplication {
        if created.uuid?.isEmpty == false, created.id != nil { return created }
        let apps = try await service.findInternalApps(bundleID: ipa.bundleIdentifier)
        let candidates = apps.filter { $0.id != previous?.id }
        if let match = candidates.first(where: { $0.id == created.id && created.id != nil })
            ?? candidates.first(where: { VersionComparator.compare($0.displayVersion, ipa.shortVersion) == .orderedSame }) {
            return match
        }
        throw UEMError.unexpectedResponse("could not locate the newly created version")
    }

    /// Takes the previous version's rule (identifiers stripped) but keeps the new rule's
    /// top-level identifiers so the PUT updates the new app's own rule record.
    static func mergedForRestore(expected: AssignmentRuleDocument, carried: AssignmentRuleDocument) -> AssignmentRuleDocument {
        var restored = expected.preparedForTransfer()
        if let id = carried.raw["id"] { restored.raw["id"] = id }
        if let uuid = carried.raw["uuid"] { restored.raw["uuid"] = uuid }
        return restored
    }
}
