import Foundation
import Observation

/// The ordered stages of deploying one IPA to one UEM server.
nonisolated enum DeploymentStep: Int, CaseIterable, Identifiable, Sendable {
    case authenticate
    case locate
    case snapshot
    case upload
    case create
    case validate
    case review
    case publish
    case retire

    var id: Int { rawValue }

    var code: String {
        switch self {
        case .authenticate: "AUTH"
        case .locate: "LOCATE"
        case .snapshot: "SNAPSHOT"
        case .upload: "UPLOAD"
        case .create: "CREATE"
        case .validate: "VERIFY"
        case .review: "REVIEW"
        case .publish: "PUBLISH"
        case .retire: "RETIRE"
        }
    }

    var title: String {
        switch self {
        case .authenticate: "Authenticate"
        case .locate: "Locate existing app"
        case .snapshot: "Snapshot assignments & app config"
        case .upload: "Upload IPA"
        case .create: "Create new version"
        case .validate: "Verify assignments & app config"
        case .review: "Operator review"
        case .publish: "Publish assignments"
        case .retire: "Retire previous version"
        }
    }
}

nonisolated enum StepState: Sendable, Equatable {
    case pending, active, done, skipped, failed
}

nonisolated enum TargetStatus: Equatable, Sendable {
    case queued
    case running
    case awaitingReview
    case succeeded
    case completedWithWarnings(String)
    case failed(String)
    case skipped(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .succeeded, .completedWithWarnings, .failed, .skipped, .cancelled: true
        case .queued, .running, .awaitingReview: false
        }
    }

    var isActive: Bool { self == .running || self == .awaitingReview }

    var label: String {
        switch self {
        case .queued: "QUEUED"
        case .running: "IN PROGRESS"
        case .awaitingReview: "AWAITING REVIEW"
        case .succeeded: "COMPLETE"
        case .completedWithWarnings: "COMPLETE • WARN"
        case .failed: "FAILED"
        case .skipped: "SKIPPED"
        case .cancelled: "ABORTED"
        }
    }
}

/// User-tunable behavior of the deployment pipeline.
nonisolated struct DeploymentOptions: Codable, Hashable, Sendable {
    /// Retire the previously active version after the new one is published.
    var retirePreviousVersion = true
    /// Pause before publishing so the operator can inspect and edit assignments / app config.
    var reviewBeforePublish = true
    /// If UEM did not carry assignments over faithfully, re-apply the previous version's rule.
    var restoreAssignmentsIfMissing = true
    /// Upload as a brand-new app when no existing version is found (no assignments are created).
    var allowNewApplications = false
}

/// Decision made by the operator at the review checkpoint.
enum ReviewDecision: Equatable {
    case publish(AssignmentRuleDocument)
    case skipPublish
    case abort
}

/// Suspends a pipeline until the operator approves or aborts. Resumes exactly once.
@Observable
final class ReviewGate {
    private var continuation: CheckedContinuation<ReviewDecision, Never>?
    private var pendingDecision: ReviewDecision?
    private(set) var isResolved = false

    func wait() async -> ReviewDecision {
        if Task.isCancelled { return .abort }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let pendingDecision {
                    continuation.resume(returning: pendingDecision)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.abort) }
        }
    }

    func resolve(_ decision: ReviewDecision) {
        guard !isResolved else { return }
        isResolved = true
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: decision)
        } else {
            pendingDecision = decision
        }
    }
}

/// Deployment of one IPA to one server.
@Observable
final class DeploymentTarget: Identifiable {
    let id = UUID()
    let server: ServerProfile

    var status: TargetStatus = .queued
    var stepStates: [DeploymentStep: StepState] = [:]
    var currentStep: DeploymentStep?
    var uploadProgress: Double = 0
    var detail: String = "Standing by"
    var warnings: [String] = []

    var previousApp: UEMApplication?
    var newApp: UEMApplication?
    /// Assignment rule of the previous version (the known-good baseline).
    var expectedRule: AssignmentRuleDocument?
    /// Rule UEM carried over to the new version.
    var carriedRule: AssignmentRuleDocument?
    /// Rule that will be published (editable during review).
    var workingRule: AssignmentRuleDocument?
    var discrepancies: [AssignmentDiscrepancy] = []
    var restoredFromPrevious = false
    /// Smart Groups returned for this server's Organization Group and available to a new distribution.
    var availableSmartGroups: [UEMSmartGroup] = []
    var smartGroupNames: [String: String] = [:]
    var reviewGate: ReviewGate?

    var startedAt: Date?
    var finishedAt: Date?

    init(server: ServerProfile) {
        self.server = server
        reset()
    }

    func reset() {
        status = .queued
        stepStates = Dictionary(uniqueKeysWithValues: DeploymentStep.allCases.map { ($0, StepState.pending) })
        currentStep = nil
        uploadProgress = 0
        detail = "Standing by"
        warnings = []
        previousApp = nil
        newApp = nil
        expectedRule = nil
        carriedRule = nil
        workingRule = nil
        discrepancies = []
        restoredFromPrevious = false
        availableSmartGroups = []
        smartGroupNames = [:]
        reviewGate = nil
        startedAt = nil
        finishedAt = nil
    }

    func state(of step: DeploymentStep) -> StepState { stepStates[step] ?? .pending }

    func smartGroupName(_ uuid: String) -> String {
        smartGroupNames[uuid.lowercased()] ?? uuid
    }
}

/// An IPA staged for deployment to one or more servers.
@Observable
final class DeploymentQueueItem: Identifiable {
    let id = UUID()
    let stagedFileURL: URL
    let fileName: String
    let metadata: IPAMetadata
    let addedAt = Date()
    var targets: [DeploymentTarget] = []

    init(stagedFileURL: URL, fileName: String, metadata: IPAMetadata) {
        self.stagedFileURL = stagedFileURL
        self.fileName = fileName
        self.metadata = metadata
    }

    var isActive: Bool { targets.contains { $0.status.isActive } }
    var hasLaunched: Bool { !targets.isEmpty }
    var isFinished: Bool { !targets.isEmpty && targets.allSatisfy { $0.status.isFinished } }

    func target(for serverID: UUID) -> DeploymentTarget? {
        targets.first { $0.server.id == serverID }
    }
}
