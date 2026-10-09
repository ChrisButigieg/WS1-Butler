import SwiftUI
import UniformTypeIdentifiers

/// Identifies the target whose review sheet is open.
struct ReviewContext: Identifiable {
    let item: DeploymentQueueItem
    let target: DeploymentTarget
    var id: UUID { target.id }
}

/// Applications › Native — queue IPAs and deploy them to every selected UEM server.
struct NativeAppsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: AppSection?

    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var reviewContext: ReviewContext?
    @State private var confirmAbort = false
    @State private var contentWidth: CGFloat = 1100

    private var coordinator: DeploymentCoordinator { model.coordinator }
    private var isWide: Bool { contentWidth >= 900 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(breadcrumb: "Applications › Native", title: "IPA Deployment") {
                    if isWide { statsRow }
                }
                if !isWide { statsRow }

                if isWide {
                    HStack(alignment: .top, spacing: 20) {
                        controlColumn.frame(width: 360)
                        queueColumn
                    }
                } else {
                    controlColumn
                    queueColumn
                }
            }
            .padding(24)
            .frame(maxWidth: 1500)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.ipa], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await coordinator.importFiles(urls) }
            case .failure(let error):
                model.log.record(.error, "File picker failed: \(error.localizedDescription)", source: "QUEUE")
            }
        }
        .dropDestination(for: IPADropFile.self) { files, _ in
            Task { await coordinator.importFiles(files.map(\.url)) }
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .sheet(item: $reviewContext) { context in
            ReviewView(item: context.item, target: context.target)
        }
        .confirmationDialog("Abort all deployments?", isPresented: $confirmAbort, titleVisibility: .visible) {
            Button("Abort All", role: .destructive) { coordinator.abortAll() }
        } message: {
            Text("Running deployments stop at the next safe checkpoint. Uploads already accepted by UEM are not rolled back.")
        }
        .onAppear(perform: syncDefaultSelection)
        .onChange(of: model.servers.servers) { syncDefaultSelection() }
    }

    /// Selects every enabled, fully configured server the first time servers become available.
    private func syncDefaultSelection() {
        let valid = Set(model.servers.enabledServers.filter(model.servers.isConfigured).map(\.id))
        coordinator.selectedServerIDs = coordinator.selectedServerIDs.intersection(valid)
        if coordinator.selectedServerIDs.isEmpty { coordinator.selectedServerIDs = valid }
    }

    // MARK: Stats

    private var statsRow: some View {
        let targets = coordinator.queue.flatMap(\.targets)
        return FlowLayout(spacing: 10) {
            StatTile(label: "Payloads", value: coordinator.queue.count, color: HUD.cyan)
            StatTile(label: "Active", value: targets.filter { $0.status == .running }.count, color: HUD.teal)
            StatTile(label: "Review", value: targets.filter { $0.status == .awaitingReview }.count, color: HUD.amber)
            StatTile(label: "Complete", value: targets.filter {
                if case .succeeded = $0.status { return true }
                if case .completedWithWarnings = $0.status { return true }
                return false
            }.count, color: HUD.green)
            StatTile(label: "Failed", value: targets.filter {
                if case .failed = $0.status { return true }
                return false
            }.count, color: HUD.red)
        }
    }

    // MARK: Control column

    private var controlColumn: some View {
        VStack(spacing: 16) {
            intakePanel
            targetsPanel
            OptionsPanel(options: Bindable(coordinator).options)
            launchPanel
        }
    }

    private var intakePanel: some View {
        HUDPanel("Payload Intake") {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundStyle(isDropTargeted ? HUD.green : HUD.cyan.opacity(0.55))
                        .background(
                            (isDropTargeted ? HUD.green : HUD.cyan).opacity(isDropTargeted ? 0.10 : 0.04),
                            in: .rect(cornerRadius: 10)
                        )
                    VStack(spacing: 8) {
                        Image(systemName: coordinator.isImporting ? "hourglass" : "square.and.arrow.down.on.square")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(isDropTargeted ? HUD.green : HUD.cyan)
                            .symbolEffect(.pulse, isActive: coordinator.isImporting || isDropTargeted)
                        Text(coordinator.isImporting ? "ANALYZING PAYLOAD…" : "DROP .IPA FILES HERE")
                            .font(.hud(.footnote, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(HUD.text)
                        Text("Multiple files supported")
                            .font(.caption)
                            .foregroundStyle(HUD.dim)
                    }
                    .padding(.vertical, 22)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Drop zone for IPA files")

                Button {
                    showImporter = true
                } label: {
                    Label("Browse for IPAs…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .hudSecondaryButton()
                .disabled(coordinator.isImporting)
                .accessibilityIdentifier("browseIPAButton")

                if !coordinator.importErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(coordinator.importErrors, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(HUD.amber)
                        }
                        Button("Dismiss") { coordinator.dismissImportErrors() }
                            .font(.caption.bold())
                            .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var targetsPanel: some View {
        HUDPanel("Target Servers") {
            if model.servers.servers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No UEM servers configured. Add your Dev, Test, and Prod consoles to begin.")
                        .font(.callout)
                        .foregroundStyle(HUD.dim)
                    Button {
                        selection = .servers
                    } label: {
                        Label("Configure Servers", systemImage: "server.rack")
                    }
                    .hudSecondaryButton()
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(model.servers.servers) { server in
                        ServerTargetRow(server: server,
                                        isConfigured: server.isEnabled && model.servers.isConfigured(server),
                                        isSelected: selectionBinding(for: server.id))
                    }
                }
            }
        }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding {
            coordinator.selectedServerIDs.contains(id)
        } set: { selected in
            if selected { coordinator.selectedServerIDs.insert(id) } else { coordinator.selectedServerIDs.remove(id) }
        }
    }

    private var selectedServers: [ServerProfile] {
        model.servers.servers.filter {
            coordinator.selectedServerIDs.contains($0.id) && $0.isEnabled && model.servers.isConfigured($0)
        }
    }

    private var launchPanel: some View {
        let pending = coordinator.unlaunchedItems.count
        let servers = selectedServers
        let operations = pending * servers.count
        return HUDPanel("Execute", accent: coordinator.isRunning ? HUD.green : HUD.cyan) {
            VStack(alignment: .leading, spacing: 12) {
                Text(operations > 0
                     ? "\(pending) payload\(pending == 1 ? "" : "s") × \(servers.count) server\(servers.count == 1 ? "" : "s") = \(operations) operation\(operations == 1 ? "" : "s")"
                     : (pending == 0 ? "Queue IPAs to arm deployment." : "Select at least one configured server."))
                    .font(.hud(.footnote, weight: .semibold))
                    .foregroundStyle(operations > 0 ? HUD.text : HUD.dim)

                Button {
                    coordinator.launch(servers: servers)
                } label: {
                    Label("ENGAGE DEPLOYMENT", systemImage: "bolt.horizontal.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .hudPrimaryButton()
                .disabled(operations == 0)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("engageButton")

                if coordinator.isRunning {
                    Button(role: .destructive) {
                        confirmAbort = true
                    } label: {
                        Label("ABORT ALL", systemImage: "xmark.octagon.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .hudPrimaryButton(tint: HUD.red)
                    .accessibilityIdentifier("abortButton")
                }
            }
        }
    }

    // MARK: Queue column

    private var queueColumn: some View {
        HUDPanel("Deployment Queue") {
            if coordinator.queue.contains(where: \.isFinished) {
                Button("Clear Finished") { withAnimation { coordinator.clearFinished() } }
                    .font(.hud(.caption, weight: .semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("clearFinishedButton")
            }
        } content: {
            if coordinator.queue.isEmpty {
                emptyQueue
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(coordinator.queue) { item in
                        QueueItemCard(
                            item: item,
                            pendingServers: selectedServers,
                            canRemove: coordinator.canRemove(item),
                            onRemove: { withAnimation { coordinator.remove(item) } },
                            onReview: { target in reviewContext = ReviewContext(item: item, target: target) },
                            onRetry: { target in coordinator.retry(target) }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.snappy, value: coordinator.queue.map(\.id))
            }
        }
    }

    private var emptyQueue: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 54, weight: .ultraLight))
                .foregroundStyle(HUD.cyan.opacity(0.6))
                .symbolEffect(.breathe)
            Text("NO PAYLOADS QUEUED")
                .font(.hud(.headline, weight: .bold))
                .tracking(2)
                .foregroundStyle(HUD.text)
            Text("Drop the IPAs you received from the developer, then press Engage. Each app is uploaded to every selected server in parallel.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(HUD.dim)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("emptyQueue")
    }
}

// MARK: - Server target row

private struct ServerTargetRow: View {
    let server: ServerProfile
    let isConfigured: Bool
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack(spacing: 10) {
                EnvironmentBadge(environment: server.environment)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.displayName)
                        .font(.hud(.callout, weight: .semibold))
                        .foregroundStyle(HUD.text)
                    Text(isConfigured ? "OG \(server.organizationGroupID) • \(server.authMethod.rawValue)" : "Incomplete or disabled")
                        .font(.hud(.caption2))
                        .foregroundStyle(isConfigured ? HUD.dim : HUD.amber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(HUD.color(for: server.environment))
        .disabled(!isConfigured)
        .accessibilityIdentifier("target.\(server.displayName)")
    }
}

// MARK: - Options

private struct OptionsPanel: View {
    @Binding var options: DeploymentOptions

    var body: some View {
        HUDPanel("Mission Parameters") {
            VStack(alignment: .leading, spacing: 12) {
                option("Retire previous version", "After the new version is published.", $options.retirePreviousVersion)
                option("Review before publish", "Pause to verify assignments & app config.", $options.reviewBeforePublish)
                option("Auto-restore assignments", "Re-apply the previous version's assignments if UEM did not carry them over exactly.", $options.restoreAssignmentsIfMissing)
                option("Create new apps", "Upload even when the app doesn't exist on a server yet.", $options.allowNewApplications)
            }
        }
    }

    private func option(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hud(.callout, weight: .semibold))
                    .foregroundStyle(HUD.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(HUD.cyan)
    }
}
