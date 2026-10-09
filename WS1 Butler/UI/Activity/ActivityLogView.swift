import SwiftUI

/// Command › Activity Log — timestamped operational record of every API action.
struct ActivityLogView: View {
    @Environment(AppModel.self) private var model
    @State private var minimumLevel: LogLevel? = nil
    @State private var searchText = ""
    @State private var confirmClear = false

    private var filtered: [LogEntry] {
        model.log.entries.filter { entry in
            (minimumLevel == nil || entry.level == minimumLevel)
                && (searchText.isEmpty
                    || entry.message.localizedCaseInsensitiveContains(searchText)
                    || entry.source.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(breadcrumb: "Command › Activity", title: "Ops Log") {
                HStack(spacing: 10) {
                    ShareLink(item: model.log.exportText,
                              preview: SharePreview("WS1 Butler Activity Log")) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .hudSecondaryButton()
                    .disabled(model.log.entries.isEmpty)

                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .hudSecondaryButton()
                    .disabled(model.log.entries.isEmpty)
                }
            }

            HStack(spacing: 12) {
                Picker("Level", selection: $minimumLevel) {
                    Text("All").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .labelsHidden()

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(HUD.dim)
                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.hud(.callout))
                }
                .padding(8)
                .background(HUD.void.opacity(0.7), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HUD.cyan.opacity(0.25)))
            }

            HUDPanel("Telemetry Stream") {
                Text("\(filtered.count) ENTRIES")
                    .font(.hud(.caption2, weight: .semibold))
                    .foregroundStyle(HUD.dim)
            } content: {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { entry in
                            LogRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(minHeight: 300)
            }
        }
        .padding(24)
        .accessibilityIdentifier("activityLogScreen")
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Log", role: .destructive) { model.log.clear() }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    private var color: Color {
        switch entry.level {
        case .info: HUD.dim
        case .success: HUD.green
        case .warning: HUD.amber
        case .error: HUD.red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .foregroundStyle(HUD.dim)
            Text(entry.level.rawValue)
                .foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            Text(entry.source)
                .foregroundStyle(HUD.cyan.opacity(0.85))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(entry.level == .info ? HUD.text : color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.hud(.caption))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.level.rawValue), \(entry.source): \(entry.message)")
        .accessibilityIdentifier("logEntry")
    }
}
