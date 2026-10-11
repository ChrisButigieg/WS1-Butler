import SwiftUI

/// One queued IPA and its per-server deployment status.
struct QueueItemCard: View {
    let item: DeploymentQueueItem
    let pendingServers: [ServerProfile]
    let canRemove: Bool
    let onRemove: () -> Void
    let onReview: (DeploymentTarget) -> Void
    let onRetry: (DeploymentTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(HUD.cyan.opacity(0.2))
            if item.targets.isEmpty {
                awaitingLaunch
            } else {
                VStack(spacing: 12) {
                    ForEach(item.targets) { target in
                        TargetRow(target: target, onReview: { onReview(target) }, onRetry: { onRetry(target) })
                    }
                }
            }
        }
        .padding(14)
        .background(HUD.void.opacity(0.55), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queueItem.\(item.metadata.bundleIdentifier)")
    }

    private var borderColor: Color {
        if item.targets.contains(where: { $0.status == .awaitingReview }) { return HUD.amber }
        if item.targets.contains(where: { if case .failed = $0.status { true } else { false } }) { return HUD.red }
        if item.isActive { return HUD.cyan }
        if item.isFinished { return HUD.green }
        return HUD.dim
    }

    private var header: some View {
        let ipa = item.metadata
        return HStack(alignment: .top, spacing: 14) {
            AppIconView(data: ipa.iconData)
            VStack(alignment: .leading, spacing: 6) {
                Text(ipa.displayName)
                    .font(.hud(.title3, weight: .bold))
                    .foregroundStyle(HUD.text)
                Text(ipa.bundleIdentifier)
                    .font(.hud(.caption))
                    .foregroundStyle(HUD.cyan.opacity(0.85))
                    .textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { telemetry }
                    VStack(alignment: .leading, spacing: 6) { telemetry }
                }
            }
            Spacer(minLength: 0)
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(HUD.dim)
                }
                .buttonStyle(.borderless)
                .help("Remove from queue")
                .accessibilityLabel("Remove \(ipa.displayName) from queue")
            }
        }
    }

    @ViewBuilder
    private var telemetry: some View {
        let ipa = item.metadata
        TelemetryLabel(label: "Version", value: ipa.shortVersion)
        TelemetryLabel(label: "Build", value: ipa.buildVersion)
        TelemetryLabel(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(ipa.fileSize), countStyle: .file))
        if let minimum = ipa.minimumOSVersion {
            TelemetryLabel(label: "Min OS", value: minimum)
        }
    }

    private var awaitingLaunch: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge")
                .foregroundStyle(HUD.dim)
            Text(pendingServers.isEmpty ? "Awaiting launch — no servers selected" : "Awaiting launch →")
                .font(.hud(.caption, weight: .semibold))
                .foregroundStyle(HUD.dim)
            ForEach(pendingServers) { server in
                EnvironmentBadge(environment: server.environment)
            }
        }
    }
}

/// Status of one (IPA, server) deployment.
struct TargetRow: View {
    let target: DeploymentTarget
    let onReview: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                identity.frame(width: 170, alignment: .leading)
                progress
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { identity; Spacer(); actions }
                progress
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: 8) {
            EnvironmentBadge(environment: target.server.environment)
            Text(target.server.displayName)
                .font(.hud(.callout, weight: .semibold))
                .foregroundStyle(HUD.text)
                .lineLimit(1)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 5) {
            StepTrack(target: target)
            if target.status == .running, target.currentStep == .upload {
                ProgressView(value: target.uploadProgress)
                    .tint(HUD.cyan)
                    .accessibilityLabel("Upload progress")
            }
            HStack(spacing: 6) {
                Text(target.currentStep.map { "[\($0.code)]" } ?? "")
                    .font(.hud(.caption2, weight: .bold))
                    .foregroundStyle(HUD.color(for: target.status))
                Text(target.detail)
                    .font(.hud(.caption2))
                    .foregroundStyle(HUD.dim)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if target.status == .running, target.currentStep == .upload {
                    Spacer()
                    Text(target.uploadProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.hud(.caption2, weight: .bold))
                        .foregroundStyle(HUD.cyan)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            StatusChip(status: target.status)
            if target.status == .awaitingReview {
                Button(action: onReview) {
                    Label("REVIEW & CONFIGURE", systemImage: "checklist")
                }
                .hudPrimaryButton(tint: HUD.amber)
                .accessibilityIdentifier("reviewButton.\(target.server.displayName)")
            } else if target.newApp != nil || target.expectedRule != nil {
                Button(action: onReview) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Show assignments and app config")
                .accessibilityLabel("Details for \(target.server.displayName)")
            }
            if isRetryable {
                Button(action: onRetry) {
                    Label("RETRY", systemImage: "arrow.clockwise")
                }
                .hudSecondaryButton()
                .accessibilityIdentifier("retryButton.\(target.server.displayName)")
            }
        }
        .fixedSize()
    }

    private var isRetryable: Bool {
        switch target.status {
        case .failed, .cancelled, .skipped: true
        default: false
        }
    }
}

/// Renders the IPA's icon, or a HUD placeholder.
struct AppIconView: View {
    let data: Data?
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let image {
                image.resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [HUD.cyan.opacity(0.35), HUD.teal.opacity(0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "app.dashed")
                        .font(.system(size: size * 0.45, weight: .light))
                        .foregroundStyle(HUD.text)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(HUD.cyan.opacity(0.4), lineWidth: 1))
        .shadow(color: HUD.cyan.opacity(0.25), radius: 8)
        .accessibilityHidden(true)
    }

    private var image: Image? {
        guard let data else { return nil }
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }
}
