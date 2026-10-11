import SwiftUI

/// Operator checkpoint: inspect the assignment groups and app configuration that will be
/// published to the new version, edit config values, then approve, skip, or abort.
/// Opens read-only when the target is not awaiting review.
struct ReviewView: View {
    let item: DeploymentQueueItem
    let target: DeploymentTarget

    @Environment(\.dismiss) private var dismiss
    @State private var rule: AssignmentRuleDocument = .empty
    @State private var loaded = false
    @State private var confirmAbort = false
    @State private var showingNewDistribution = false
    @State private var distributionError = ""
    @State private var showingDistributionError = false

    private var isInteractive: Bool { target.status == .awaitingReview && target.reviewGate != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                HUDBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary
                        if isInteractive {
                            DistributionCreationPanel {
                                showingNewDistribution = true
                            }
                        } else {
                            ReviewClosedInfoPanel()
                        }
                        if !target.discrepancies.isEmpty { discrepanciesPanel }
                        assignmentsPanel
                    }
                    .padding(20)
                }
            }
            .navigationTitle(isInteractive ? "Review & Publish" : "Deployment Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if isInteractive { decisionBar }
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 600, idealHeight: 760)
        .onAppear {
            guard !loaded else { return }
            rule = target.workingRule ?? target.carriedRule ?? target.expectedRule ?? .empty
            isInteractiveOnOpen = isInteractive
            loaded = true
        }
        .onChange(of: target.status) {
            // Another path (e.g. Abort All) resolved the review; close the sheet.
            if target.status != .awaitingReview, isInteractiveOnOpen { dismiss() }
        }
        .confirmationDialog("Abort this deployment?", isPresented: $confirmAbort, titleVisibility: .visible) {
            Button("Abort", role: .destructive) { decide(.abort) }
        } message: {
            Text("The new version stays uploaded but unpublished, and the previous version remains active.")
        }
        .sheet(isPresented: $showingNewDistribution) {
            NewDistributionEditorView(
                smartGroups: target.availableSmartGroups,
                unavailableSmartGroupUUIDs: rule.unavailableSmartGroupUUIDs,
                onCreate: addDistribution
            )
        }
        .alert("Distribution Not Added", isPresented: $showingDistributionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(distributionError)
        }
    }

    @State private var isInteractiveOnOpen = false

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(isInteractive ? "Later" : "Close") { dismiss() }
                .accessibilityIdentifier("reviewCloseButton")
        }
    }

    // MARK: Summary

    private var summary: some View {
        HUDPanel("Operation", accent: HUD.color(for: target.server.environment)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AppIconView(data: item.metadata.iconData, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.metadata.displayName)
                            .font(.hud(.title3, weight: .bold))
                            .foregroundStyle(HUD.text)
                        Text(item.metadata.bundleIdentifier)
                            .font(.hud(.caption))
                            .foregroundStyle(HUD.cyan)
                    }
                    Spacer()
                    EnvironmentBadge(environment: target.server.environment)
                    Text(target.server.displayName)
                        .font(.hud(.callout, weight: .semibold))
                        .foregroundStyle(HUD.text)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { versionTelemetry }
                    VStack(alignment: .leading, spacing: 8) { versionTelemetry }
                }
                if target.restoredFromPrevious {
                    Label("UEM did not carry assignments over exactly. The previous version's assignments were restored and will be published.",
                          systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.callout)
                        .foregroundStyle(HUD.teal)
                }
            }
        }
    }

    @ViewBuilder
    private var versionTelemetry: some View {
        TelemetryLabel(label: "Previous", value: target.previousApp.map { "v\($0.displayVersion) • ID \($0.id ?? 0)" } ?? "None")
        TelemetryLabel(label: "New", value: target.newApp.map { "v\($0.displayVersion) • ID \($0.id ?? 0)" } ?? "v\(item.metadata.shortVersion)", color: HUD.green)
        if let assigned = target.previousApp?.assignedDeviceCount {
            TelemetryLabel(label: "Devices assigned", value: "\(assigned)")
        }
        TelemetryLabel(label: "Status", value: target.status.label, color: HUD.color(for: target.status))
    }

    // MARK: Discrepancies

    private var discrepanciesPanel: some View {
        HUDPanel("Discrepancies vs previous version", accent: HUD.amber) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(target.discrepancies) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(issue.kind.rawValue)
                            .font(.hud(.caption2, weight: .heavy))
                            .foregroundStyle(HUD.amber)
                            .frame(width: 150, alignment: .leading)
                        Text("\(issue.assignmentName): \(issue.detail)")
                            .font(.callout)
                            .foregroundStyle(HUD.text)
                    }
                }
            }
        }
    }

    // MARK: Assignments

    private var assignmentsPanel: some View {
        HUDPanel(isInteractive ? "Assignments to publish" : "Assignments", accent: HUD.cyan) {
            if isInteractive, let expected = target.expectedRule, !expected.isEmpty {
                Button("Restore Previous") {
                    rule = DeploymentEngine.mergedForRestore(expected: expected, carried: target.carriedRule ?? .empty)
                }
                .font(.hud(.caption, weight: .semibold))
                .buttonStyle(.borderless)
                .help("Replace with the previous version's assignments and app config")
            }
        } content: {
            if rule.assignments.isEmpty {
                Label("No assignment groups. The new version will not be published to any devices; assign it in the UEM console.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(HUD.amber)
            } else {
                VStack(spacing: 14) {
                    ForEach(rule.assignments) { assignment in
                        AssignmentCard(
                            assignment: assignment,
                            baseline: baseline(for: assignment),
                            smartGroupName: target.smartGroupName,
                            isEditable: isInteractive,
                            valueBinding: { key in configBinding(assignmentIndex: assignment.index, key: key) }
                        )
                    }
                }
            }
        }
    }

    private func baseline(for assignment: AssignmentSummary) -> [String: String] {
        guard let expected = target.expectedRule?.assignments.first(where: { $0.matchKey == assignment.matchKey }) else { return [:] }
        return Dictionary(expected.configuration.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func configBinding(assignmentIndex: Int, key: String) -> Binding<String> {
        Binding {
            rule.assignments.first { $0.index == assignmentIndex }?
                .configuration.first { $0.key == key }?.value ?? ""
        } set: { newValue in
            rule.setConfigurationValue(newValue, forKey: key, assignmentIndex: assignmentIndex)
        }
    }

    // MARK: Decision

    private var decisionBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                confirmAbort = true
            } label: {
                Label("Abort", systemImage: "xmark.octagon")
            }
            .hudSecondaryButton()
            .accessibilityIdentifier("reviewAbortButton")

            Button {
                decide(.skipPublish)
            } label: {
                Label("Don't Publish", systemImage: "pause.circle")
            }
            .hudSecondaryButton()
            .help("Keep the new version unpublished and the previous version active")
            .accessibilityIdentifier("reviewSkipButton")

            Spacer()

            Button {
                decide(.publish(rule))
            } label: {
                Label("APPROVE & PUBLISH", systemImage: "checkmark.seal.fill")
                    .padding(.horizontal, 6)
            }
            .hudPrimaryButton(tint: HUD.green)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("reviewApproveButton")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func decide(_ decision: ReviewDecision) {
        target.reviewGate?.resolve(decision)
        dismiss()
    }

    private func addDistribution(_ distribution: NewDistribution) {
        do {
            try rule.appendDistribution(distribution)
        } catch {
            distributionError = error.localizedDescription
            showingDistributionError = true
        }
    }
}

/// Prominent entry point for adding a distribution while the UEM publish step is paused.
private struct DistributionCreationPanel: View {
    let onCreate: () -> Void

    var body: some View {
        HUDPanel("New Distribution", accent: HUD.green) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Configure the assignment before it is sent to UEM.", systemImage: "slider.horizontal.3")
                    .font(.hud(.callout, weight: .semibold))
                    .foregroundStyle(HUD.text)
                Text("Add Smart Groups, delivery method, restrictions, and optional app configuration. These changes remain local until you select Approve & Publish.")
                    .font(.callout)
                    .foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onCreate) {
                    Label("CREATE NEW DISTRIBUTION", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .hudPrimaryButton(tint: HUD.green)
                .accessibilityIdentifier("createDistributionButton")
            }
        }
    }
}

/// Explains why historic deployment details cannot safely be edited after the publish decision.
private struct ReviewClosedInfoPanel: View {
    var body: some View {
        HUDPanel("Distribution Editing", accent: HUD.amber) {
            VStack(alignment: .leading, spacing: 8) {
                Label("This deployment is read-only.", systemImage: "lock.fill")
                    .font(.hud(.callout, weight: .semibold))
                    .foregroundStyle(HUD.amber)
                Text("To create or edit a distribution, enable Review before MDM publish before starting the deployment, then select Review before Approve & Publish.")
                    .font(.callout)
                    .foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One assignment group with its smart groups, delivery method, and app configuration.
private struct AssignmentCard: View {
    let assignment: AssignmentSummary
    let baseline: [String: String]
    let smartGroupName: (String) -> String
    let isEditable: Bool
    let valueBinding: (String) -> Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("P\(assignment.priority)")
                    .font(.hud(.caption2, weight: .heavy))
                    .foregroundStyle(HUD.void)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(HUD.cyan, in: .rect(cornerRadius: 3))
                Text(assignment.name.isEmpty ? "Unnamed assignment" : assignment.name)
                    .font(.hud(.headline, weight: .bold))
                    .foregroundStyle(HUD.text)
                Spacer()
                Text(assignment.deliveryMethod.replacingOccurrences(of: "_", with: " "))
                    .font(.hud(.caption2, weight: .bold))
                    .foregroundStyle(assignment.deliveryMethod == "AUTO" ? HUD.green : HUD.teal)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(HUD.teal.opacity(0.5)))
            }

            if !assignment.smartGroupUUIDs.isEmpty {
                FlowChips(items: assignment.smartGroupUUIDs.map(smartGroupName))
            }

            if !assignment.description.isEmpty {
                Text(assignment.description)
                    .font(.callout)
                    .foregroundStyle(HUD.dim)
            }

            if let effectiveDate = assignment.effectiveDate, !effectiveDate.isEmpty {
                Label("Begins \(effectiveDate)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(HUD.teal)
            }

            if assignment.restrictions.hasValues {
                AssignmentRestrictionSummaryView(restrictions: assignment.restrictions)
            }

            if assignment.configuration.isEmpty {
                Text("No managed app configuration")
                    .font(.caption)
                    .foregroundStyle(HUD.dim)
            } else {
                VStack(spacing: 0) {
                    ForEach(assignment.configuration) { entry in
                        configRow(entry)
                        Divider().overlay(HUD.cyan.opacity(0.1))
                    }
                }
                .background(HUD.void.opacity(0.5), in: .rect(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(HUD.panelRaised.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.cyan.opacity(0.18)))
    }

    @ViewBuilder
    private func configRow(_ entry: AppConfigEntry) -> some View {
        let previous = baseline[entry.key]
        let changed = previous != nil && previous != entry.value
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.key)
                    .font(.hud(.callout, weight: .semibold))
                    .foregroundStyle(HUD.text)
                    .textSelection(.enabled)
                Text(entry.type)
                    .font(.hud(.caption2))
                    .foregroundStyle(HUD.dim)
            }
            .frame(width: 220, alignment: .leading)

            if isEditable && entry.isEditable {
                if entry.type.uppercased() == "BOOLEAN" {
                    Toggle("", isOn: Binding {
                        valueBinding(entry.key).wrappedValue.lowercased() == "true"
                    } set: {
                        valueBinding(entry.key).wrappedValue = $0 ? "true" : "false"
                    })
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(HUD.cyan)
                    Spacer()
                } else {
                    TextField("Value", text: valueBinding(entry.key))
                        .textFieldStyle(.plain)
                        .font(.hud(.callout))
                        .foregroundStyle(HUD.text)
                        .padding(6)
                        .background(HUD.void, in: .rect(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(HUD.cyan.opacity(0.3)))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Value for \(entry.key)")
                }
            } else {
                Text(entry.value.isEmpty ? "—" : entry.value)
                    .font(.hud(.callout))
                    .foregroundStyle(HUD.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if changed, let previous {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(HUD.amber)
                    .help("Changed from previous version: \(previous)")
                    .accessibilityLabel("Changed from previous value \(previous)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct AssignmentRestrictionSummaryView: View {
    let restrictions: AssignmentRestrictionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Restrictions")
                .font(.hud(.caption2, weight: .bold))
                .tracking(1)
                .foregroundStyle(HUD.dim)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { statusLabels }
                VStack(alignment: .leading, spacing: 4) { statusLabels }
            }
        }
    }

    @ViewBuilder
    private var statusLabels: some View {
        RestrictionStatusLabel(title: "Remove on unenroll", value: restrictions.removeOnUnenroll)
        RestrictionStatusLabel(title: "Prevent removal", value: restrictions.preventRemoval)
        RestrictionStatusLabel(title: "Prevent backup", value: restrictions.preventApplicationBackup)
        RestrictionStatusLabel(title: "MDM managed", value: restrictions.makeAppMDMManaged)
    }
}

private struct RestrictionStatusLabel: View {
    let title: String
    let value: Bool?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: value == true ? "checkmark.circle.fill" : "circle")
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(value == true ? HUD.green : HUD.dim)
        .accessibilityLabel("\(title): \(value == true ? "on" : "off")")
    }
}

/// Wrapping row of smart group chips.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item, systemImage: "person.3.fill")
                    .font(.hud(.caption, weight: .semibold))
                    .foregroundStyle(HUD.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(HUD.cyan.opacity(0.12), in: .capsule)
                    .overlay(Capsule().strokeBorder(HUD.cyan.opacity(0.35)))
            }
        }
    }
}

/// Simple flow layout that wraps children onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(proposal.width ?? widest, widest), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview("Review", traits: .fixedLayout(width: 900, height: 820)) {
    let metadata = IPAMetadata(bundleIdentifier: "mil.afrc.missionplanner", shortVersion: "1.1.0", buildVersion: "42",
                               displayName: "Mission Planner", minimumOSVersion: "17.0", deviceFamilies: [2], fileSize: 48_000_000)
    let item = DeploymentQueueItem(stagedFileURL: URL(filePath: "/tmp/x.ipa"), fileName: "x.ipa", metadata: metadata)
    var server = ServerProfile()
    server.name = "Production"
    server.environment = .production
    let target = DeploymentTarget(server: server)
    target.previousApp = MockUEMService.sampleExistingApp(bundleID: metadata.bundleIdentifier)
    target.newApp = UEMApplication(actualFileVersion: "1.1.0", entityID: .init(value: 2002), uuid: "new")
    target.expectedRule = MockUEMService.sampleRule()
    let carried = MockUEMService.sampleRule(configValue: "https://api.test.example.mil")
    target.carriedRule = carried
    target.workingRule = carried
    target.discrepancies = AssignmentComparator.compare(expected: MockUEMService.sampleRule(), actual: carried)
    target.smartGroupNames = ["sg-flightline": "Flight Line iPads", "sg-maint": "Maintainers", "sg-qa": "QA Testers"]
    target.status = .awaitingReview
    target.reviewGate = ReviewGate()
    return ReviewView(item: item, target: target)
        .preferredColorScheme(.dark)
}
#endif
