import SwiftUI

/// Create or edit a UEM server profile and its credentials.
struct ServerEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State private var draft: ServerProfile
    @State private var secrets = ServerSecrets()
    @State private var ogText: String
    @State private var lookupCode = ""
    @State private var lookupResults: [UEMOrganizationGroup] = []
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @State private var confirmDelete = false
    @State private var showValidation = false

    enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    init(profile: ServerProfile, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: profile)
        _ogText = State(initialValue: profile.organizationGroupID > 0 ? String(profile.organizationGroupID) : "")
    }

    private var validationErrors: [ServerValidationError] {
        ServerValidator.validate(draft, secrets: secrets)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HUDBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        identityPanel
                        endpointPanel
                        authPanel
                        diagnosticsPanel
                        if !isNew { dangerPanel }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(isNew ? "New Server" : draft.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .accessibilityIdentifier("saveServerButton")
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 640, idealHeight: 780)
        .onAppear {
            if !isNew { secrets = model.servers.secrets(for: draft.id) }
        }
        .onChange(of: ogText) {
            draft.organizationGroupID = Int(ogText.filter(\.isNumber)) ?? 0
        }
        .confirmationDialog("Delete \(draft.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Server", role: .destructive) {
                do {
                    try model.servers.delete(id: draft.id)
                    dismiss()
                } catch {
                    saveError = error.localizedDescription
                }
            }
        } message: {
            Text("The profile and its Keychain credentials will be removed from this device.")
        }
    }

    // MARK: Panels

    private var identityPanel: some View {
        HUDPanel("Identity", accent: HUD.color(for: draft.environment)) {
            VStack(alignment: .leading, spacing: 14) {
                HUDField(label: "Name") {
                    TextField("e.g. AFRC Production", text: $draft.name)
                        .accessibilityIdentifier("serverNameField")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("ENVIRONMENT").font(.hud(.caption2, weight: .bold)).tracking(1.5).foregroundStyle(HUD.dim)
                    Picker("Environment", selection: $draft.environment) {
                        ForEach(ServerEnvironment.allCases) { env in
                            Text(env.title).tag(env)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Toggle(isOn: $draft.isEnabled) {
                    Text("Enabled for deployments")
                        .font(.hud(.callout, weight: .semibold))
                        .foregroundStyle(HUD.text)
                }
                .toggleStyle(.switch)
                .tint(HUD.green)
            }
        }
    }

    private var endpointPanel: some View {
        HUDPanel("Endpoint") {
            VStack(alignment: .leading, spacing: 14) {
                HUDField(label: "REST API URL", hint: "Your API server, e.g. https://as1234.awmdm.com — found under Groups & Settings › System › Advanced › Site URLs.") {
                    TextField("https://", text: $draft.apiURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .accessibilityIdentifier("serverURLField")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    HUDField(label: "Organization Group ID") {
                        TextField("e.g. 570", text: $ogText)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .accessibilityIdentifier("serverOGField")
                    }
                    HUDField(label: "Lookup by Group ID") {
                        HStack {
                            TextField("OG code", text: $lookupCode)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Button("Find", action: lookup)
                                .buttonStyle(.borderless)
                                .disabled(lookupCode.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if !draft.organizationGroupName.isEmpty {
                    Label(draft.organizationGroupName, systemImage: "building.2.fill")
                        .font(.hud(.caption, weight: .semibold))
                        .foregroundStyle(HUD.teal)
                }
                if !lookupResults.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lookupResults) { group in
                            Button {
                                ogText = String(group.id)
                                draft.organizationGroupName = group.name ?? ""
                                lookupResults = []
                            } label: {
                                HStack {
                                    Text(group.name ?? "Unnamed").foregroundStyle(HUD.text)
                                    Text(group.groupID ?? "").foregroundStyle(HUD.dim)
                                    Spacer()
                                    Text("ID \(group.id)").foregroundStyle(HUD.cyan)
                                }
                                .font(.hud(.caption))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private var authPanel: some View {
        HUDPanel("Authentication") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Method", selection: $draft.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("authMethodPicker")

                switch draft.authMethod {
                case .oauth:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TOKEN REGION").font(.hud(.caption2, weight: .bold)).tracking(1.5).foregroundStyle(HUD.dim)
                        Picker("Token region", selection: $draft.oauthRegion) {
                            ForEach(OAuthRegion.allCases) { region in
                                Text(region.rawValue).tag(region)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    HUDField(label: "Token URL", hint: draft.oauthRegion == .custom ? "On-premises or dedicated tenants: copy the Token URL from Groups & Settings › Configurations › OAuth Client Management." : nil) {
                        if draft.oauthRegion == .custom {
                            TextField("https://…/connect/token", text: $draft.customTokenURL)
                                .autocorrectionDisabled()
                        } else {
                            Text(draft.tokenURLString).foregroundStyle(HUD.dim).textSelection(.enabled)
                        }
                    }
                    HUDField(label: "Client ID") {
                        TextField("OAuth client ID", text: $draft.clientID)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    HUDField(label: "Client Secret") {
                        SecureField("OAuth client secret", text: $secrets.clientSecret)
                    }
                    HUDField(label: "aw-tenant-code (optional)", hint: "Not required for OAuth; sent when provided.") {
                        SecureField("REST API key", text: $secrets.tenantCode)
                    }
                case .basic:
                    HUDField(label: "Username") {
                        TextField("API admin username", text: $draft.username)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityIdentifier("serverUsernameField")
                    }
                    HUDField(label: "Password") {
                        SecureField("Password", text: $secrets.password)
                            .accessibilityIdentifier("serverPasswordField")
                    }
                    HUDField(label: "aw-tenant-code", hint: "REST API key from Groups & Settings › System › Advanced › API › REST API.") {
                        SecureField("REST API key", text: $secrets.tenantCode)
                            .accessibilityIdentifier("serverTenantField")
                    }
                }
            }
        }
    }

    private var diagnosticsPanel: some View {
        HUDPanel("Diagnostics", accent: diagnosticsColor) {
            VStack(alignment: .leading, spacing: 12) {
                if showValidation || !isNew, !validationErrors.isEmpty {
                    ForEach(validationErrors, id: \.self) { error in
                        Label(error.errorDescription ?? "", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(HUD.amber)
                    }
                }
                HStack(spacing: 12) {
                    Button(action: testConnection) {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .hudSecondaryButton()
                    .disabled(!validationErrors.isEmpty || testState == .running)
                    .accessibilityIdentifier("testConnectionButton")

                    switch testState {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .success(let message):
                        Label(message, systemImage: "checkmark.seal.fill").foregroundStyle(HUD.green).font(.callout)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(HUD.red).font(.callout)
                    }
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(HUD.red)
                        .font(.callout)
                }
            }
        }
    }

    private var diagnosticsColor: Color {
        switch testState {
        case .success: HUD.green
        case .failure: HUD.red
        default: HUD.cyan
        }
    }

    private var dangerPanel: some View {
        HUDPanel("Danger Zone", accent: HUD.red) {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Server", systemImage: "trash")
            }
            .hudSecondaryButton()
        }
    }

    // MARK: Actions

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized = try? ServerValidator.normalizedAPIBase(draft.apiURL) {
            draft.apiURL = normalized.absoluteString
        }
        secrets.tenantCode = secrets.tenantCode.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only keep the credentials relevant to the chosen method.
        if draft.authMethod == .oauth { secrets.password = "" } else { secrets.clientSecret = "" }

        guard !draft.name.isEmpty else {
            showValidation = true
            saveError = ServerValidationError.missingName.errorDescription
            return
        }
        if !validationErrors.isEmpty { draft.isEnabled = false }
        do {
            try model.servers.save(draft, secrets: secrets)
            model.log.record(.info, "Server profile saved: \(draft.displayName)", source: "CONFIG")
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func testConnection() {
        testState = .running
        let profile = draft
        let creds = secrets
        Task {
            do {
                let client = try model.makeClient(for: profile, secrets: creds)
                let group = try await client.testConnection()
                draft.organizationGroupName = group.name ?? draft.organizationGroupName
                testState = .success("Linked • \(group.name ?? "OG \(profile.organizationGroupID)")")
                model.log.record(.success, "Connection verified", source: "\(profile.environment.rawValue):\(profile.displayName)")
            } catch {
                testState = .failure(error.localizedDescription)
                model.log.record(.error, "Connection test failed: \(error.localizedDescription)", source: "\(profile.environment.rawValue):\(profile.displayName)")
            }
        }
    }

    private func lookup() {
        let code = lookupCode.trimmingCharacters(in: .whitespaces)
        let profile = draft
        let creds = secrets
        testState = .running
        Task {
            do {
                let client = try model.makeClient(for: profile, secrets: creds)
                let results = try await client.searchOrganizationGroups(groupID: code)
                lookupResults = results
                testState = results.isEmpty ? .failure("No organization group matches '\(code)'") : .idle
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
