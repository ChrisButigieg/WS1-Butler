import Foundation
import Testing
@testable import WS1Butler

@Suite("Deployment engine")
struct DeploymentEngineTests {
    private let bundleID = "mil.afrc.missionplanner"

    private func run(_ mock: MockUEMService, options: DeploymentOptions,
                     item: DeploymentQueueItem? = nil) async -> DeploymentTarget {
        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        await engine.run(item: item ?? TestSupport.queueItem(bundleID: bundleID), target: target, options: options)
        return target
    }

    private var autoPublish: DeploymentOptions {
        var options = DeploymentOptions()
        options.reviewBeforePublish = false
        return options
    }

    @Test("Happy path: upload, carry over, verify, publish, retire")
    func happyPath() async throws {
        let mock = MockUEMService.populated(bundleID: bundleID)
        let target = await run(mock, options: autoPublish)

        #expect(target.status == .succeeded)
        #expect(mock.calls == [
            "testConnection",
            "findInternalApps",
            "assignmentRule:old-app-uuid",
            "smartGroupNames",
            "uploadBlob:MissionPlanner.ipa",
            "beginInstall",
            "assignmentRule:new-app-uuid",
            "updateAssignmentRule:new-app-uuid",
            "retireApp:1001"
        ])
        let request = try #require(mock.beginInstallRequests.first)
        #expect(request.blobID == 777)
        #expect(request.carryOverAssignments)
        #expect(request.locationGroupID == 570)
        #expect(request.applicationName == "Mission Planner")
        #expect(request.pushMode == "Auto")
        #expect(request.supportedModels.model?.compactMap(\.modelID) == [2])
        #expect(target.discrepancies.isEmpty)
        #expect(mock.publishedRules["new-app-uuid"]?.assignments.count == 2)
        #expect(target.uploadProgress == 1)
        #expect(DeploymentStep.allCases.allSatisfy { target.state(of: $0) == .done || $0 == .review })
        #expect(target.state(of: .review) == .skipped)
    }

    @Test("Skips servers where the app does not exist unless new apps are allowed")
    func skipsUnknownApps() async {
        let mock = MockUEMService()
        let target = await run(mock, options: autoPublish)
        guard case .skipped = target.status else {
            Issue.record("Expected skipped, got \(target.status)")
            return
        }
        #expect(!mock.calls.contains { $0.hasPrefix("uploadBlob") })
    }

    @Test("Creates a new app when allowed, without retiring anything")
    func createsNewApp() async throws {
        let mock = MockUEMService()
        var options = autoPublish
        options.allowNewApplications = true
        let target = await run(mock, options: options, item: TestSupport.queueItem(bundleID: bundleID, families: [1, 2]))

        guard case .completedWithWarnings = target.status else {
            Issue.record("Expected completed with warnings, got \(target.status)")
            return
        }
        #expect(mock.retiredAppIDs.isEmpty)
        let request = try #require(mock.beginInstallRequests.first)
        #expect(request.pushMode == "OnDemand")
        #expect(request.applicationName == "Mission Planner")
        #expect(request.supportedModels.model?.compactMap(\.modelID) == [1, 3, 2])
    }

    @Test("Deletes the uploaded blob when version creation fails")
    func cleansUpBlob() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        mock.failBeginInstall = UEMError.http(status: 400, message: "Version exists", activityID: nil)
        let target = await run(mock, options: autoPublish)

        #expect(target.status == .failed("HTTP 400: Version exists"))
        #expect(target.state(of: .create) == .failed)
        #expect(mock.deletedBlobIDs == [777])
        #expect(mock.retiredAppIDs.isEmpty)
        #expect(mock.publishedRules.isEmpty)
    }

    @Test("Partial create acknowledgement is resolved before operator review")
    func resolvesPartialCreateBeforeReview() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        var indexedApp = mock.newAppTemplate
        indexedApp.bundleID = bundleID
        // UEM builds can index CFBundleVersion before CFBundleShortVersionString.
        indexedApp.actualFileVersion = "42"
        indexedApp.appVersion = "1.1.0"
        mock.newAppTemplate = indexedApp
        mock.beginInstallResponseOverride = UEMApplication()

        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        let task = Task {
            await engine.run(
                item: TestSupport.queueItem(bundleID: bundleID),
                target: target,
                options: DeploymentOptions()
            )
        }

        await TestSupport.waitUntil { target.status == .awaitingReview }

        #expect(target.newApp?.id == 2002)
        #expect(target.newApp?.uuid == "new-app-uuid")
        #expect(mock.calls.filter { $0 == "findInternalApps" }.count == 2)
        #expect(mock.publishedRules.isEmpty)

        target.reviewGate?.resolve(.skipPublish)
        await task.value

        if case .completedWithWarnings = target.status {} else {
            Issue.record("Expected a completed deployment that awaits explicit publishing")
        }
        #expect(mock.retiredAppIDs.isEmpty)
    }

    @Test("UUID-only create acknowledgement is indexed before operator review")
    func resolvesUUIDOnlyCreateBeforeReview() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        var indexedApp = mock.newAppTemplate
        indexedApp.bundleID = bundleID
        indexedApp.actualFileVersion = "1.1.0"
        mock.newAppTemplate = indexedApp
        mock.beginInstallResponseOverride = UEMApplication(uuid: "new-app-uuid")

        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        let task = Task {
            await engine.run(
                item: TestSupport.queueItem(bundleID: bundleID),
                target: target,
                options: DeploymentOptions()
            )
        }

        await TestSupport.waitUntil { target.status == .awaitingReview }

        #expect(target.newApp?.id == 2002)
        #expect(target.newApp?.uuid == "new-app-uuid")
        #expect(mock.calls.filter { $0 == "findInternalApps" }.count == 2)
        #expect(mock.publishedRules.isEmpty)

        target.reviewGate?.resolve(.skipPublish)
        await task.value

        #expect(mock.retiredAppIDs.isEmpty)
    }

    @Test("Stops after authentication failure")
    func authFailure() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        mock.failAuthentication = UEMError.http(status: 401, message: "Unauthorized", activityID: nil)
        let target = await run(mock, options: autoPublish)
        #expect(mock.calls == ["testConnection"])
        #expect(target.state(of: .authenticate) == .failed)
        if case .failed = target.status {} else { Issue.record("Expected failure") }
    }

    @Test("Restores previous assignments when UEM did not carry them over")
    func restoresAssignments() async throws {
        let mock = MockUEMService.populated(bundleID: bundleID)
        mock.carriedRuleOverride = AssignmentRuleDocument(raw: .object(["id": .int(900), "assignments": .array([])]))
        let target = await run(mock, options: autoPublish)

        #expect(target.status == .succeeded)
        #expect(target.restoredFromPrevious)
        #expect(target.discrepancies.filter { $0.kind == .missingAssignment }.count == 2)
        let published = try #require(mock.publishedRules["new-app-uuid"])
        #expect(published.assignments.count == 2)
        #expect(published.raw["id"] == .int(900))
        #expect(published.assignments[0].configuration.first?.value == "https://api.dev.example.mil")
        #expect(mock.retiredAppIDs == [1001])
    }

    @Test("Reports but does not fix discrepancies when auto-restore is off")
    func reportsDiscrepancies() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        mock.carriedRuleOverride = MockUEMService.sampleRule(configValue: "https://wrong.example.mil")
        var options = autoPublish
        options.restoreAssignmentsIfMissing = false
        let target = await run(mock, options: options)

        guard case .completedWithWarnings = target.status else {
            Issue.record("Expected warnings, got \(target.status)")
            return
        }
        #expect(target.discrepancies.count == 1)
        #expect(mock.publishedRules["new-app-uuid"]?.assignments.first?.configuration.first?.value == "https://wrong.example.mil")
    }

    @Test("Review: operator edits app config and approves")
    func reviewApprove() async throws {
        let mock = MockUEMService.populated(bundleID: bundleID)
        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        let task = Task { await engine.run(item: TestSupport.queueItem(bundleID: bundleID), target: target, options: DeploymentOptions()) }

        await TestSupport.waitUntil { target.status == .awaitingReview }
        #expect(mock.publishedRules.isEmpty)
        let request = try #require(mock.beginInstallRequests.first)
        #expect(!request.carryOverAssignments)
        #expect(target.carriedRule?.isEmpty == true)
        #expect(target.workingRule?.assignments.count == 2)
        var rule = try #require(target.workingRule)
        rule.setConfigurationValue("https://api.prod.example.mil", forKey: "ServerURL", assignmentIndex: 0)
        target.reviewGate?.resolve(.publish(rule))
        await task.value

        #expect(target.status == .succeeded)
        #expect(mock.publishedRules["new-app-uuid"]?.assignments.first?.configuration.first?.value == "https://api.prod.example.mil")
        #expect(mock.retiredAppIDs == [1001])
    }

    @Test("Review: abort leaves the previous version untouched")
    func reviewAbort() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        let task = Task { await engine.run(item: TestSupport.queueItem(bundleID: bundleID), target: target, options: DeploymentOptions()) }

        await TestSupport.waitUntil { target.status == .awaitingReview }
        target.reviewGate?.resolve(.abort)
        await task.value

        #expect(target.status == .cancelled)
        #expect(mock.publishedRules.isEmpty)
        #expect(mock.retiredAppIDs.isEmpty)
    }

    @Test("Review: skipping publish also skips retire")
    func reviewSkipPublish() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        let task = Task { await engine.run(item: TestSupport.queueItem(bundleID: bundleID), target: target, options: DeploymentOptions()) }

        await TestSupport.waitUntil { target.status == .awaitingReview }
        target.reviewGate?.resolve(.skipPublish)
        await task.value

        guard case .completedWithWarnings = target.status else {
            Issue.record("Expected warnings, got \(target.status)")
            return
        }
        #expect(target.state(of: .publish) == .skipped)
        #expect(target.state(of: .retire) == .skipped)
        #expect(mock.retiredAppIDs.isEmpty)
    }

    @Test("Review: skipping publish never retires an unassigned previous version")
    func reviewSkipPublishWithEmptyRule() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        mock.rules["old-app-uuid"] = .empty
        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        let task = Task {
            await engine.run(item: TestSupport.queueItem(bundleID: bundleID), target: target, options: DeploymentOptions())
        }

        await TestSupport.waitUntil { target.status == .awaitingReview }
        target.reviewGate?.resolve(.skipPublish)
        await task.value

        #expect(mock.publishedRules.isEmpty)
        #expect(mock.retiredAppIDs.isEmpty)
        #expect(target.state(of: .retire) == .skipped)
    }

    @Test("Cancelling the task while in review aborts safely")
    func cancelDuringReview() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        let engine = DeploymentEngine(log: ActivityLog()) { _ in mock }
        let target = DeploymentTarget(server: TestSupport.server())
        let task = Task { await engine.run(item: TestSupport.queueItem(bundleID: bundleID), target: target, options: DeploymentOptions()) }

        await TestSupport.waitUntil { target.status == .awaitingReview }
        task.cancel()
        await task.value
        #expect(target.status == .cancelled)
        #expect(mock.publishedRules.isEmpty)
    }

    @Test("Retire can be disabled")
    func retireDisabled() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        var options = autoPublish
        options.retirePreviousVersion = false
        let target = await run(mock, options: options)
        #expect(target.status == .succeeded)
        #expect(target.state(of: .retire) == .skipped)
        #expect(mock.retiredAppIDs.isEmpty)
    }

    @Test("A retire failure is reported after a successful publish")
    func retireFailure() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        mock.failRetire = UEMError.http(status: 500, message: "Retire failed", activityID: nil)
        let target = await run(mock, options: autoPublish)
        #expect(target.status == .failed("HTTP 500: Retire failed"))
        #expect(target.state(of: .publish) == .done)
        #expect(target.state(of: .retire) == .failed)
    }

    @Test("Warns when the IPA is not newer than the deployed version")
    func versionWarning() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        let target = await run(mock, options: autoPublish, item: TestSupport.queueItem(bundleID: bundleID, version: "1.0.0"))
        guard case .completedWithWarnings(let message) = target.status else {
            Issue.record("Expected warning, got \(target.status)")
            return
        }
        #expect(message.contains("not newer"))
    }

    @Test("Chooses the highest active version as the previous version")
    func choosesHighestActive() async {
        let mock = MockUEMService.populated(bundleID: bundleID)
        var retired = MockUEMService.sampleExistingApp(bundleID: bundleID, version: "1.0.5")
        retired.status = "Retired"
        retired.entityID = .init(value: 1005)
        var older = MockUEMService.sampleExistingApp(bundleID: bundleID, version: "0.9.0")
        older.entityID = .init(value: 999)
        mock.existingApps = [older, retired, MockUEMService.sampleExistingApp(bundleID: bundleID)]
        let target = await run(mock, options: autoPublish)
        #expect(target.previousApp?.id == 1001)
        #expect(mock.retiredAppIDs == [1001])
    }
}

@Suite("Deployment coordinator")
struct DeploymentCoordinatorTests {
    private func makeCoordinator(mocks: [UUID: MockUEMService]) -> DeploymentCoordinator {
        let engine = DeploymentEngine(log: ActivityLog()) { profile in
            guard let mock = mocks[profile.id] else { throw UEMError.invalidConfiguration("no mock") }
            return mock
        }
        let coordinator = DeploymentCoordinator(engine: engine, log: ActivityLog(),
                                                defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        var options = DeploymentOptions()
        options.reviewBeforePublish = false
        coordinator.options = options
        return coordinator
    }

    @Test("Deploys every queued app to Dev, Test and Prod in parallel")
    func multiServerMultiApp() async {
        let servers = [TestSupport.server("Dev", environment: .development),
                       TestSupport.server("Test", environment: .test),
                       TestSupport.server("Prod", environment: .production)]
        var mocks: [UUID: MockUEMService] = [:]
        for server in servers {
            let mock = MockUEMService.populated(bundleID: "mil.afrc.a")
            mock.existingApps.append(MockUEMService.sampleExistingApp(bundleID: "mil.afrc.b"))
            mocks[server.id] = mock
        }
        let coordinator = makeCoordinator(mocks: mocks)
        coordinator.enqueue(TestSupport.queueItem(bundleID: "mil.afrc.a"))
        coordinator.enqueue(TestSupport.queueItem(bundleID: "mil.afrc.b"))

        coordinator.launch(servers: servers)
        #expect(coordinator.isRunning)
        await coordinator.waitUntilIdle()

        #expect(!coordinator.isRunning)
        for item in coordinator.queue {
            #expect(item.targets.count == 3)
            #expect(item.targets.allSatisfy { $0.status == .succeeded })
        }
        for mock in mocks.values {
            #expect(mock.beginInstallRequests.count == 2)
        }
    }

    @Test("Items queued while running are picked up by active workers")
    func lateItems() async {
        let server = TestSupport.server()
        let mock = MockUEMService.populated(bundleID: "mil.afrc.a")
        mock.latency = .milliseconds(20)
        let coordinator = makeCoordinator(mocks: [server.id: mock])
        coordinator.enqueue(TestSupport.queueItem(bundleID: "mil.afrc.a"))
        coordinator.launch(servers: [server])

        let directory = try? TestSupport.temporaryDirectory()
        if let url = directory?.appending(path: "Late.ipa") {
            try? ZipFixtureWriter.ipa(bundleID: "mil.afrc.a", version: "1.2.0").write(to: url)
            await coordinator.importFiles([url])
        }
        await coordinator.waitUntilIdle()
        #expect(coordinator.queue.count == 2)
        #expect(coordinator.queue.allSatisfy { $0.targets.first?.status == .succeeded })
    }

    @Test("Abort all cancels queued and in-review deployments")
    func abortAll() async {
        let server = TestSupport.server()
        let mock = MockUEMService.populated(bundleID: "mil.afrc.a")
        let coordinator = makeCoordinator(mocks: [server.id: mock])
        coordinator.options.reviewBeforePublish = true
        coordinator.enqueue(TestSupport.queueItem(bundleID: "mil.afrc.a"))
        coordinator.enqueue(TestSupport.queueItem(bundleID: "mil.afrc.a", version: "1.2.0"))
        coordinator.launch(servers: [server])

        await TestSupport.waitUntil { coordinator.pendingReviewCount == 1 }
        coordinator.abortAll()
        await coordinator.waitUntilIdle()

        #expect(coordinator.queue.flatMap(\.targets).allSatisfy { $0.status == .cancelled })
        #expect(mock.publishedRules.isEmpty)
    }

    @Test("Failed targets can be retried")
    func retry() async {
        let server = TestSupport.server()
        let mock = MockUEMService.populated(bundleID: "mil.afrc.a")
        mock.failUpload = URLError(.networkConnectionLost)
        let coordinator = makeCoordinator(mocks: [server.id: mock])
        coordinator.enqueue(TestSupport.queueItem(bundleID: "mil.afrc.a"))
        coordinator.launch(servers: [server])
        await coordinator.waitUntilIdle()

        let target = coordinator.queue[0].targets[0]
        if case .failed = target.status {} else { Issue.record("Expected failure, got \(target.status)") }

        mock.failUpload = nil
        coordinator.retry(target)
        await coordinator.waitUntilIdle()
        #expect(target.status == .succeeded)
    }

    @Test("Imports IPAs, rejects duplicates and invalid files")
    func importValidation() async throws {
        let coordinator = makeCoordinator(mocks: [:])
        let directory = try TestSupport.temporaryDirectory()
        let good = directory.appending(path: "Good.ipa")
        try ZipFixtureWriter.ipa(bundleID: "mil.afrc.good").write(to: good)
        let copy = directory.appending(path: "GoodCopy.ipa")
        try ZipFixtureWriter.ipa(bundleID: "mil.afrc.good").write(to: copy)
        let bad = directory.appending(path: "Bad.ipa")
        try Data("garbage".utf8).write(to: bad)
        let notIPA = directory.appending(path: "readme.txt")
        try Data("hi".utf8).write(to: notIPA)

        await coordinator.importFiles([good, copy, bad, notIPA])

        #expect(coordinator.queue.count == 1)
        #expect(coordinator.queue.first?.metadata.bundleIdentifier == "mil.afrc.good")
        #expect(coordinator.importErrors.count == 3)

        let item = try #require(coordinator.queue.first)
        let staged = item.stagedFileURL
        coordinator.remove(item)
        #expect(coordinator.queue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Deployment options persist")
    func optionsPersist() {
        let suite = "test.\(UUID().uuidString)"
        let engine = DeploymentEngine(log: ActivityLog()) { _ in MockUEMService() }
        let first = DeploymentCoordinator(engine: engine, log: ActivityLog(), defaults: UserDefaults(suiteName: suite))
        first.options.retirePreviousVersion = false
        first.options.allowNewApplications = true
        let second = DeploymentCoordinator(engine: engine, log: ActivityLog(), defaults: UserDefaults(suiteName: suite))
        #expect(second.options == first.options)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

@Suite("Review gate")
struct ReviewGateTests {
    @Test("A decision made before waiting is delivered")
    func earlyDecision() async {
        let gate = ReviewGate()
        gate.resolve(.skipPublish)
        #expect(await gate.wait() == .skipPublish)
    }

    @Test("Only the first decision counts")
    func resolvesOnce() async {
        let gate = ReviewGate()
        let waiter = Task { await gate.wait() }
        await Task.yield()
        gate.resolve(.abort)
        gate.resolve(.skipPublish)
        #expect(await waiter.value == .abort)
        #expect(gate.isResolved)
    }
}
