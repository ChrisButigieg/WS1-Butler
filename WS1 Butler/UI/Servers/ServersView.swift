import SwiftUI

/// Command › Servers — manage UEM consoles (Dev / Test / Prod / …).
struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditorContext?

    struct EditorContext: Identifiable {
        let profile: ServerProfile
        let isNew: Bool
        var id: UUID { profile.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(breadcrumb: "Command › Servers", title: "UEM Links") {
                    Button {
                        editing = EditorContext(profile: ServerProfile(), isNew: true)
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                    .hudPrimaryButton()
                    .accessibilityIdentifier("addServerButton")
                }

                if let error = model.servers.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(HUD.amber)
                }

                if model.servers.servers.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                        ForEach(model.servers.servers) { server in
                            Button {
                                editing = EditorContext(profile: server, isNew: false)
                            } label: {
                                ServerCard(server: server, isConfigured: model.servers.isConfigured(server))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("serverCard.\(server.displayName)")
                        }
                    }
                }

                securityNote
            }
            .padding(24)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { context in
            ServerEditorView(profile: context.profile, isNew: context.isNew)
        }
    }

    private var emptyState: some View {
        HUDPanel("No links established") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add each Workspace ONE UEM console you deploy to. A typical setup is three servers — Development, Test, and Production — which all receive uploads in parallel.")
                    .font(.callout)
                    .foregroundStyle(HUD.dim)
                HStack(spacing: 12) {
                    Button {
                        model.servers.createStandardEnvironments()
                    } label: {
                        Label("Quick Setup: DEV / TEST / PROD", systemImage: "square.stack.3d.up.fill")
                    }
                    .hudPrimaryButton()
                    .accessibilityIdentifier("quickSetupButton")
                }
            }
        }
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(HUD.green)
            Text("Credentials are stored only in this device's Keychain (never synced or backed up). All traffic uses HTTPS with TLS 1.2+, and redirects to other hosts are blocked.")
                .font(.caption)
                .foregroundStyle(HUD.dim)
        }
        .padding(.top, 8)
    }
}

private struct ServerCard: View {
    let server: ServerProfile
    let isConfigured: Bool

    var body: some View {
        let accent = HUD.color(for: server.environment)
        HUDPanel(nil, accent: accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    EnvironmentBadge(environment: server.environment)
                    Text(server.displayName)
                        .font(.hud(.headline, weight: .bold))
                        .foregroundStyle(HUD.text)
                    Spacer()
                    Image(systemName: isConfigured ? (server.isEnabled ? "checkmark.shield.fill" : "pause.circle.fill") : "exclamationmark.shield.fill")
                        .foregroundStyle(isConfigured ? (server.isEnabled ? HUD.green : HUD.dim) : HUD.amber)
                        .accessibilityLabel(isConfigured ? (server.isEnabled ? "Ready" : "Disabled") : "Incomplete")
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        TelemetryLabel(label: "Host", value: URL(string: server.apiURL)?.host() ?? (server.apiURL.isEmpty ? "—" : server.apiURL))
                        TelemetryLabel(label: "Auth", value: server.authMethod.rawValue)
                    }
                    GridRow {
                        TelemetryLabel(label: "Org Group", value: server.organizationGroupID > 0
                                       ? "\(server.organizationGroupID)\(server.organizationGroupName.isEmpty ? "" : " • \(server.organizationGroupName)")"
                                       : "—")
                        TelemetryLabel(label: "State", value: isConfigured ? (server.isEnabled ? "ARMED" : "DISABLED") : "INCOMPLETE",
                                       color: isConfigured ? (server.isEnabled ? HUD.green : HUD.dim) : HUD.amber)
                    }
                }
            }
        }
        .contentShape(.rect)
    }
}

#Preview(traits: .fixedLayout(width: 1100, height: 760)) {
    ZStack {
        HUDBackground()
        ServersView()
    }
    .environment(AppModel(arguments: ["-demo"]))
    .preferredColorScheme(.dark)
}
