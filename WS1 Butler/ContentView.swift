import SwiftUI

/// Top-level destinations. New modules (Profiles, Devices, …) slot in here.
enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case nativeApps
    case servers
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeApps: "Native"
        case .servers: "Servers"
        case .activity: "Activity Log"
        }
    }

    var systemImage: String {
        switch self {
        case .nativeApps: "app.badge.checkmark"
        case .servers: "server.rack"
        case .activity: "list.bullet.rectangle.portrait"
        }
    }
}

/// Planned modules shown (disabled) so operators can see the roadmap.
private let upcomingModules: [(String, String)] = [
    ("Public Apps", "bag"),
    ("Profiles", "doc.badge.gearshape"),
    ("Devices", "ipad.and.iphone"),
    ("Products", "shippingbox")
]

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppSection? = .nativeApps
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            ZStack {
                HUDBackground()
                switch selection ?? .nativeApps {
                case .nativeApps: NativeAppsView(selection: $selection)
                case .servers: ServersView()
                case .activity: ActivityLogView()
                }
            }
        }
        .tint(HUD.cyan)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                brand
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }

            Section {
                sidebarRow(.nativeApps, badge: model.coordinator.queue.count)
                ForEach(upcomingModules, id: \.0) { module in
                    HStack {
                        Label(module.0, systemImage: module.1)
                        Spacer()
                        Text("SOON")
                            .font(.hud(.caption2, weight: .bold))
                            .foregroundStyle(HUD.dim)
                    }
                    .foregroundStyle(HUD.dim.opacity(0.7))
                    .selectionDisabled()
                    .accessibilityLabel("\(module.0), coming soon")
                }
            } header: {
                sectionHeader("Applications")
            }

            Section {
                sidebarRow(.servers, badge: model.servers.servers.count)
                sidebarRow(.activity, badge: nil)
            } header: {
                sectionHeader("Command")
            }
        }
        .scrollContentBackground(.hidden)
        .background(HUD.void.opacity(0.6))
        .safeAreaInset(edge: .bottom) { linkStatus }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        #if os(macOS)
        .navigationTitle("WS1 Butler")
        #else
        .navigationTitle("WS1 Butler")
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .font(.title2)
                .foregroundStyle(HUD.cyan)
                .shadow(color: HUD.cyan.opacity(0.8), radius: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text("WS1 BUTLER")
                    .font(.hud(.headline, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(HUD.text)
                Text("UEM OPERATIONS")
                    .font(.hud(.caption2, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(HUD.dim)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace One UEM Butler")
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.hud(.caption2, weight: .bold))
            .tracking(2)
            .foregroundStyle(HUD.cyan.opacity(0.75))
    }

    private func sidebarRow(_ section: AppSection, badge: Int?) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .font(.hud(.callout, weight: .semibold))
            .badge(badge ?? 0)
            .tag(section)
            .accessibilityIdentifier("nav.\(section.rawValue)")
    }

    private var linkStatus: some View {
        let enabled = model.servers.enabledServers.count
        let running = model.coordinator.isRunning
        return HStack(spacing: 8) {
            Circle()
                .fill(running ? HUD.green : (enabled > 0 ? HUD.cyan : HUD.dim))
                .frame(width: 7, height: 7)
                .shadow(color: running ? HUD.green : .clear, radius: 4)
            Text(running ? "OPS ACTIVE" : "STANDBY")
                .font(.hud(.caption2, weight: .bold))
                .tracking(1.5)
            Spacer()
            Text("\(enabled) LINK\(enabled == 1 ? "" : "S")")
                .font(.hud(.caption2, weight: .semibold))
                .foregroundStyle(HUD.dim)
            if model.isDemoMode {
                Text("DEMO")
                    .font(.hud(.caption2, weight: .heavy))
                    .foregroundStyle(HUD.amber)
            }
        }
        .foregroundStyle(HUD.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

#Preview(traits: .fixedLayout(width: 1440, height: 900)) {
    RootView()
        .environment(AppModel(arguments: ["-demo"]))
        .preferredColorScheme(.dark)
}
