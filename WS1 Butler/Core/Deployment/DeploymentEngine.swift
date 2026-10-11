import Foundation

/// Runs the deployment pipeline for a single (IPA, server) pair:
///
/// 1. Authenticate and confirm the Organization Group.
/// 2. Locate the currently active internal app with the same bundle ID.
/// 3. Snapshot that version's assignment rule (smart groups, delivery, app config).
/// 4. Upload the IPA as a blob.
/// 5. Create the new version; carry assignments only for an explicit auto-publish deployment.
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
        // Carrying assignments during creation can make the new version available immediately.
        // When review is enabled, stage the snapshot locally and PUT it only after approval.
        let carryOverAssignments = !options.reviewBeforePublish

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
            let smartGroupCount: Int
            if options.reviewBeforePublish {
                // This is a required preflight for the review editor. Do not turn an API or
                // permissions failure into an empty picker: that would let an operator upload
                // an app and reach review without any assignment targets to select.
                // Keep the endpoint path visible without recording a server URL, credentials,
                // tenant code, or other sensitive request data.
                log.record(.info, "SMART GROUPS: GET /api/mdm/smartgroups/search", source: source)
                let smartGroups = try await service.smartGroups()
                target.availableSmartGroups = smartGroups
                target.smartGroupNames = Dictionary(
                    smartGroups.map { ($0.id, $0.displayName) },
                    uniquingKeysWith: { first, _ in first }
                )
                smartGroupCount = smartGroups.count
                let level: LogLevel = smartGroups.isEmpty ? .warning : .info
                log.record(level, "SMART GROUPS: Loaded \(smartGroupCount) assignment target(s)", source: source)
            } else {
                smartGroupCount = 0
            }

            guard let uuid = target.previousApp?.uuid else {
                let message = options.reviewBeforePublish
                    ? "No previous assignments; \(smartGroupCount) Smart Group(s) available for review"
                    : "No previous assignments"
                return .skipped(message)
            }
            let rule = try await service.assignmentRule(appUUID: uuid)
            target.expectedRule = rule
            let configCount = rule.assignments.reduce(0) { $0 + $1.configuration.count }
            let message = "\(rule.assignments.count) assignment group(s), \(configCount) app config key(s)"
            return .done(options.reviewBeforePublish ? "\(message), \(smartGroupCount) Smart Group(s)" : message)
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
            let request = makeBeginInstallRequest(
                blobID: blobID,
                item: item,
                previous: target.previousApp,
                server: server,
                carryOverAssignments: carryOverAssignments
            )
            let created: UEMApplication
            do {
                created = try await service.beginInstall(request)
            } catch {
                // A transport or decoding failure can occur after UEM accepts the request. Only
                // delete the blob after a definite client-side rejection; otherwise preserve it
                // so UEM's asynchronous create is not interrupted.
                if let error = error as? UEMError,
                   let status = error.statusCode,
                   (400..<500).contains(status) {
                    try? await service.deleteBlob(id: blobID)
                }
                throw error
            }
            target.newApp = try await resolveNewApp(
                created,
                service: service,
                ipa: ipa,
                previous: target.previousApp,
                target: target
            )
            return .done("Created version \(target.newApp?.displayVersion ?? ipa.shortVersion) (ID \(target.newApp?.id ?? 0))")
        }

        try await step(.validate, target, source) {
            guard let newUUID = target.newApp?.uuid else { throw UEMError.unexpectedResponse("new app has no UUID") }
            let carried = try await service.assignmentRule(appUUID: newUUID)
            target.carriedRule = carried
            target.workingRule = carried

            guard let expected = target.expectedRule else { return .skipped("No previous version to compare") }
            if !carryOverAssignments {
                target.workingRule = Self.mergedForRestore(expected: expected, carried: carried)
                if expected.isEmpty {
                    return .done("No previous assignments to stage for review")
                }
                return .done("Assignments staged for operator review")
            }
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
            target.detail = "Awaiting review — configure distributions or approve"
            log.record(.info, "Awaiting review — configure distributions or approve", source: source)
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
            guard publishApproved else {
                return .skipped("Skipped by operator — previous version kept active")
            }
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
                                 server: ServerProfile, carryOverAssignments: Bool = true) -> BeginInstallRequest {
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
            carryOverAssignments: carryOverAssignments
        )
    }

    /// `begininstall` may return the complete entity, a partial acknowledgement, or no body.
    /// UEM can also take a few seconds to index the new version, so resolve it deterministically
    /// before touching assignments or offering the review checkpoint.
    private func resolveNewApp(_ created: UEMApplication, service: UEMService, ipa: IPAMetadata,
                               previous: UEMApplication?, target: DeploymentTarget) async throws -> UEMApplication {
        let responseMatchesBundle = created.bundleID.map {
            $0.caseInsensitiveCompare(ipa.bundleIdentifier) == .orderedSame
        } ?? true
        // A full entity can be used immediately. A UUID-only acknowledgement still needs a
        // catalog round-trip so we do not race UEM's asynchronous application indexing.
        if responseMatchesBundle, (created.id ?? 0) > 0, Self.canReview(created) {
            return created
        }

        // A large IPA can take materially longer than the create acknowledgement to appear in
        // the catalog. Poll for just under a minute before declaring the accepted request lost.
        let maximumAttempts = 12
        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            let apps = try await service.findInternalApps(bundleID: ipa.bundleIdentifier)
            let candidates = apps.filter {
                $0.id != previous?.id &&
                ($0.bundleID?.caseInsensitiveCompare(ipa.bundleIdentifier) == .orderedSame || $0.bundleID == nil)
            }

            if let createdID = created.id,
               let match = candidates.first(where: { $0.id == createdID && Self.canReview($0) }) {
                return match
            }
            if let createdUUID = created.uuid,
               let match = candidates.first(where: {
                   $0.uuid?.caseInsensitiveCompare(createdUUID) == .orderedSame && Self.canReview($0)
               }) {
                return match
            }

            let versionMatches = candidates.filter {
                Self.matchesNewVersion($0, ipa: ipa) && Self.canReview($0)
            }
            if versionMatches.count == 1, let match = versionMatches.first {
                return match
            }
            if versionMatches.count > 1 {
                throw UEMError.unexpectedResponse(
                    "multiple new versions match \(ipa.shortVersion); resolve the duplicate in UEM before retrying"
                )
            }

            guard attempt < maximumAttempts else { break }
            target.detail = "Waiting for UEM to index the new version (\(attempt)/\(maximumAttempts))…"
            try await Task.sleep(for: .seconds(min(attempt, 5)))
        }

        throw UEMError.unexpectedResponse(
            "UEM accepted the create request but the new version was not found after \(maximumAttempts) checks"
        )
    }

    private static func canReview(_ app: UEMApplication) -> Bool {
        app.uuid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func matchesNewVersion(_ app: UEMApplication, ipa: IPAMetadata) -> Bool {
        [app.actualFileVersion, app.appVersion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains {
                VersionComparator.compare($0, ipa.shortVersion) == .orderedSame ||
                VersionComparator.compare($0, ipa.buildVersion) == .orderedSame
            }
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
