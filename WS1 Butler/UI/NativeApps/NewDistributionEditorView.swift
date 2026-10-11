import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Main-actor form state for a distribution that has not yet been added to the assignment-rule payload.
@MainActor
@Observable
final class NewDistributionDraft {
    var assignmentName = ""
    /// When off, the name follows the first selected Smart Group and delivery method.
    var isNameOverrideEnabled = false {
        didSet {
            if !isNameOverrideEnabled { refreshAutomaticAssignmentName() }
        }
    }
    var assignmentDescription = ""
    var deploymentBeginning = Date()
    var deliveryMethod: AppDeliveryMethod = .automatic {
        didSet { refreshAutomaticAssignmentName() }
    }
    var selectedSmartGroupUUIDs: [String] = [] {
        didSet { refreshAutomaticAssignmentName() }
    }
    var removeOnUnenroll = true
    var preventRemoval = false
    var preventApplicationBackup = true
    var makeAppMDMManaged = true
    var sendConfiguration = false
    var configuration: [NewAppConfiguration] = []

    private var smartGroupDisplayNames: [String: String] = [:]

    subscript(smartGroupSelected uuid: String, displayName displayName: String) -> Bool {
        get { selectedSmartGroupUUIDs.contains(uuid.lowercased()) }
        set {
            let normalizedUUID = uuid.lowercased()
            if newValue {
                guard !selectedSmartGroupUUIDs.contains(normalizedUUID) else { return }
                smartGroupDisplayNames[normalizedUUID] = displayName
                selectedSmartGroupUUIDs.append(normalizedUUID)
            } else {
                selectedSmartGroupUUIDs.removeAll { $0 == normalizedUUID }
            }
        }
    }

    var distribution: NewDistribution {
        NewDistribution(
            assignmentName: assignmentName,
            assignmentDescription: assignmentDescription,
            deploymentBeginning: deploymentBeginning,
            deliveryMethod: deliveryMethod,
            smartGroupUUIDs: selectedSmartGroupUUIDs,
            restrictions: NewAssignmentRestrictions(
                removeOnUnenroll: removeOnUnenroll,
                preventRemoval: preventRemoval,
                preventApplicationBackup: preventApplicationBackup,
                makeAppMDMManaged: makeAppMDMManaged
            ),
            sendConfiguration: sendConfiguration,
            configuration: configuration
        )
    }

    func addConfiguration() {
        configuration.append(NewAppConfiguration())
    }

    func replaceConfiguration(with importedConfiguration: [NewAppConfiguration]) {
        configuration = importedConfiguration
        sendConfiguration = true
    }

    private func refreshAutomaticAssignmentName() {
        guard !isNameOverrideEnabled else { return }
        guard let firstSmartGroupUUID = selectedSmartGroupUUIDs.first,
              let smartGroupName = smartGroupDisplayNames[firstSmartGroupUUID]
        else {
            assignmentName = ""
            return
        }

        let trimmedName = smartGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameWithoutPrefix = trimmedName.uppercased().hasPrefix("SG_")
            ? String(trimmedName.dropFirst(3))
            : trimmedName
        guard !nameWithoutPrefix.isEmpty else {
            assignmentName = ""
            return
        }

        let deliverySuffix: String
        switch deliveryMethod {
        case .automatic:
            deliverySuffix = "AUTO"
        case .onDemand:
            deliverySuffix = "ONDEMAND"
        }
        assignmentName = "\(nameWithoutPrefix)_\(deliverySuffix)"
    }
}

/// Creates a local assignment-rule distribution. No UEM request is made until the parent review is approved.
struct NewDistributionEditorView: View {
    let smartGroups: [UEMSmartGroup]
    let unavailableSmartGroupUUIDs: Set<String>
    let onCreate: (NewDistribution) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewDistributionDraft()
    @State private var isImportingXML = false
    @State private var errorMessage = ""
    @State private var showingError = false

    var body: some View {
        @Bindable var draft = draft

        NavigationStack {
            ZStack {
                HUDBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        DistributionDetailsSection(draft: draft)
                        SmartGroupSelectionSection(
                            draft: draft,
                            smartGroups: smartGroups,
                            unavailableSmartGroupUUIDs: unavailableSmartGroupUUIDs
                        )
                        DistributionRestrictionsSection(draft: draft)
                        AppConfigurationSection(draft: draft, isImportingXML: $isImportingXML)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("New Distribution")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Distribution") { addDistribution() }
                        .hudPrimaryButton(tint: HUD.green)
                        .accessibilityIdentifier("addDistributionButton")
                }
            }
            .fileImporter(
                isPresented: $isImportingXML,
                allowedContentTypes: [.xml, .propertyList],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                importConfiguration(from: url)
            }
            .alert("Distribution Not Added", isPresented: $showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 650, idealHeight: 820)
    }

    private func addDistribution() {
        let distribution = draft.distribution
        do {
            try distribution.validate(usedSmartGroupUUIDs: unavailableSmartGroupUUIDs)
            onCreate(distribution)
            dismiss()
        } catch {
            present(error)
        }
    }

    private func importConfiguration(from url: URL) {
        let accessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if accessingSecurityScopedResource { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 1_000_000 else {
                throw AppConfigurationXMLImportError.invalidPropertyList
            }
            draft.replaceConfiguration(with: try AppConfigurationXMLImporter.configurations(from: Data(contentsOf: url)))
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }
}

private struct DistributionDetailsSection: View {
    @Bindable var draft: NewDistributionDraft

    var body: some View {
        HUDPanel("Distribution", accent: HUD.cyan) {
            VStack(alignment: .leading, spacing: 14) {
                HUDField(label: "Distribution Name") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Required", text: $draft.assignmentName)
                            .disabled(!draft.isNameOverrideEnabled)
                            .accessibilityIdentifier("assignmentNameField")

                        Toggle("Override automatically generated name", isOn: $draft.isNameOverrideEnabled)
                            .toggleStyle(.switch)
                            .tint(HUD.cyan)
                            .font(.hud(.callout, weight: .semibold))
                            .accessibilityIdentifier("assignmentNameOverrideToggle")

                        if !draft.isNameOverrideEnabled {
                            Text("Generated from the first selected Smart Group and app delivery method.")
                                .font(.caption)
                                .foregroundStyle(HUD.dim)
                        }
                    }
                }
                HUDField(label: "Assignment Description", hint: "Optional") {
                    TextField("Optional", text: $draft.assignmentDescription, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("assignmentDescriptionField")
                }
                DatePicker(
                    "Deployment Beginning Time",
                    selection: $draft.deploymentBeginning,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .font(.hud(.callout, weight: .semibold))
                .foregroundStyle(HUD.text)

                VStack(alignment: .leading, spacing: 6) {
                    Text("APP DELIVERY METHOD")
                        .font(.hud(.caption2, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(HUD.dim)
                    Picker("App Delivery Method", selection: $draft.deliveryMethod) {
                        ForEach(AppDeliveryMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appDeliveryMethodPicker")
                }
            }
        }
    }
}

private struct SmartGroupSelectionSection: View {
    @Bindable var draft: NewDistributionDraft
    let smartGroups: [UEMSmartGroup]
    let unavailableSmartGroupUUIDs: Set<String>

    @State private var searchText = ""
    @State private var visibleSmartGroups: [UEMSmartGroup] = []

    var body: some View {
        HUDPanel("Assignment Groups", accent: HUD.teal) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select one or more Smart Groups. Groups already assigned or excluded by this app cannot be selected again.")
                    .font(.callout)
                    .foregroundStyle(HUD.dim)

                if smartGroups.isEmpty {
                    Label("No Smart Groups were returned for this Organization Group. Confirm the API account can search Smart Groups.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HUD.amber)
                } else {
                    TextField("Filter Smart Groups", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("smartGroupFilterField")

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleSmartGroups) { group in
                                SmartGroupToggleRow(
                                    group: group,
                                    isUnavailable: unavailableSmartGroupUUIDs.contains(group.id),
                                    isSelected: $draft[smartGroupSelected: group.id, displayName: group.displayName]
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .background(HUD.void.opacity(0.45), in: .rect(cornerRadius: 6))
                }
            }
        }
        .task(id: smartGroups) { refreshVisibleSmartGroups() }
        .onChange(of: searchText) { _, _ in refreshVisibleSmartGroups() }
    }

    private func refreshVisibleSmartGroups() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleSmartGroups = query.isEmpty
            ? smartGroups
            : smartGroups.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }
}

private struct SmartGroupToggleRow: View {
    let group: UEMSmartGroup
    let isUnavailable: Bool
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.hud(.callout, weight: .semibold))
                if let manager = group.managedByOrganizationGroupName, !manager.isEmpty {
                    Text("Managed by \(manager)")
                        .font(.caption)
                        .foregroundStyle(HUD.dim)
                }
                if isUnavailable {
                    Text("Already assigned or excluded")
                        .font(.caption)
                        .foregroundStyle(HUD.amber)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(HUD.cyan)
        .disabled(isUnavailable)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityIdentifier("smartGroup_\(group.id)")
    }
}

private struct DistributionRestrictionsSection: View {
    @Bindable var draft: NewDistributionDraft

    var body: some View {
        HUDPanel("Restrictions", accent: HUD.amber) {
            VStack(alignment: .leading, spacing: 8) {
                RestrictionToggleRow(
                    title: "Removal upon unenroll",
                    detail: "Remove the app when the device unenrolls.",
                    isOn: $draft.removeOnUnenroll
                )
                RestrictionToggleRow(
                    title: "Prevent Removal",
                    detail: "Prevent users from removing the managed app.",
                    isOn: $draft.preventRemoval
                )
                RestrictionToggleRow(
                    title: "Prevent Application Backup",
                    detail: "Prevent app data from being backed up to iCloud.",
                    isOn: $draft.preventApplicationBackup
                )
                RestrictionToggleRow(
                    title: "Make App MDM Managed if User Installed",
                    detail: "Allow UEM to take over management of an existing user-installed app.",
                    isOn: $draft.makeAppMDMManaged
                )
            }
        }
    }
}

private struct RestrictionToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hud(.callout, weight: .semibold))
                    .foregroundStyle(HUD.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HUD.dim)
            }
        }
        .toggleStyle(.switch)
        .tint(HUD.cyan)
        .padding(.vertical, 3)
    }
}

private struct AppConfigurationSection: View {
    @Bindable var draft: NewDistributionDraft
    @Binding var isImportingXML: Bool

    var body: some View {
        HUDPanel("App Configuration", accent: HUD.green) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Send Configuration", isOn: $draft.sendConfiguration)
                    .toggleStyle(.switch)
                    .tint(HUD.green)
                    .font(.hud(.callout, weight: .semibold))
                    .accessibilityIdentifier("sendConfigurationToggle")

                if draft.sendConfiguration {
                    HStack {
                        Button {
                            draft.addConfiguration()
                        } label: {
                            Label("Add Key/Value", systemImage: "plus")
                        }
                        .hudSecondaryButton()

                        Button {
                            isImportingXML = true
                        } label: {
                            Label("Upload XML", systemImage: "square.and.arrow.up")
                        }
                        .hudSecondaryButton()
                        .accessibilityIdentifier("uploadConfigurationXMLButton")

                        Spacer()
                    }

                    if draft.configuration.isEmpty {
                        Text("Add key/value pairs or import an XML property-list configuration.")
                            .font(.callout)
                            .foregroundStyle(HUD.dim)
                    } else {
                        VStack(spacing: 8) {
                            ForEach($draft.configuration) { $entry in
                                ConfigurationEntryEditor(entry: $entry) {
                                    draft.configuration.removeAll { $0.id == entry.id }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ConfigurationEntryEditor: View {
    @Binding var entry: NewAppConfiguration
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Key", text: $entry.key)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Configuration key")
            TextField("Value", text: $entry.value)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Configuration value")
            Picker("Type", selection: $entry.type) {
                ForEach(AppConfigurationType.simpleKeyValueCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 155)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove configuration row")
        }
    }
}
