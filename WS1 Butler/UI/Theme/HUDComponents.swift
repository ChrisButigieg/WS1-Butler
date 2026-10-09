import SwiftUI

// MARK: - Background

/// Static tactical grid backdrop with a soft phosphor glow.
struct HUDBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [HUD.void, HUD.deep, HUD.void], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let spacing: CGFloat = 36
                var minor = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(minor, with: .color(HUD.grid.opacity(0.22)), lineWidth: 0.5)

                // Reticle ticks on every 4th intersection.
                var ticks = Path()
                var tx: CGFloat = 0
                while tx <= size.width {
                    var ty: CGFloat = 0
                    while ty <= size.height {
                        ticks.move(to: CGPoint(x: tx - 3, y: ty)); ticks.addLine(to: CGPoint(x: tx + 3, y: ty))
                        ticks.move(to: CGPoint(x: tx, y: ty - 3)); ticks.addLine(to: CGPoint(x: tx, y: ty + 3))
                        ty += spacing * 4
                    }
                    tx += spacing * 4
                }
                context.stroke(ticks, with: .color(HUD.cyan.opacity(0.25)), lineWidth: 1)
            }
            RadialGradient(colors: [HUD.cyan.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [HUD.teal.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Panel

/// L-shaped targeting brackets at each corner of a rectangle.
nonisolated struct CornerBrackets: Shape {
    var length: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let l = min(length, rect.width / 3, rect.height / 3)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); path.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return path
    }
}

/// A framed HUD panel with an optional header.
struct HUDPanel<Content: View, Accessory: View>: View {
    var title: String?
    var accent: Color = HUD.cyan
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, accent: Color = HUD.cyan,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    Rectangle().fill(accent).frame(width: 3, height: 14)
                        .shadow(color: accent.opacity(0.8), radius: 4)
                    Text(title.uppercased())
                        .font(.hud(.caption, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(accent)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    accessory()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [HUD.panelRaised.opacity(0.92), HUD.panel.opacity(0.88)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.22), lineWidth: 1)
        }
        .overlay {
            CornerBrackets().stroke(accent.opacity(0.85), lineWidth: 1.5).padding(-1)
        }
    }
}

// MARK: - Badges & chips

struct EnvironmentBadge: View {
    let environment: ServerEnvironment

    var body: some View {
        let color = HUD.color(for: environment)
        Text(environment.rawValue)
            .font(.hud(.caption2, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.7), lineWidth: 1))
            .accessibilityLabel("\(environment.title) environment")
    }
}

struct StatusChip: View {
    let status: TargetStatus

    var body: some View {
        let color = HUD.color(for: status)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: color, radius: status.isActive ? 4 : 0)
            Text(status.label)
                .font(.hud(.caption2, weight: .bold))
                .tracking(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.label.lowercased())")
    }
}

/// Segmented tracker showing each pipeline step's state.
struct StepTrack: View {
    let target: DeploymentTarget

    var body: some View {
        HStack(spacing: 3) {
            ForEach(DeploymentStep.allCases) { step in
                let state = target.state(of: step)
                let isReview = step == .review && target.status == .awaitingReview
                let color = isReview ? HUD.amber : HUD.color(for: state)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(height: 6)
                    .shadow(color: state == .active || isReview ? color : .clear, radius: 4)
                    .phaseAnimator([false, true], trigger: state == .active) { view, phase in
                        view.opacity(state == .active && phase ? 0.45 : 1)
                    } animation: { _ in .easeInOut(duration: 0.6) }
                    .help("\(step.title): \(String(describing: state))")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let done = DeploymentStep.allCases.filter { target.state(of: $0) == .done }.count
        let current = target.currentStep?.title ?? "not started"
        return "\(done) of \(DeploymentStep.allCases.count) steps complete. Current step: \(current)."
    }
}

struct TelemetryLabel: View {
    let label: String
    let value: String
    var color: Color = HUD.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.hud(.caption2, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(HUD.dim)
            Text(value)
                .font(.hud(.callout, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatTile: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%02d", value))
                .font(.hud(.title2, weight: .bold))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.6), radius: 6)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(.hud(.caption2, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(HUD.dim)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.07), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Large HUD-style screen title with breadcrumb.
struct ScreenHeader<Trailing: View>: View {
    let breadcrumb: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(breadcrumb: String, title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.breadcrumb = breadcrumb
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(breadcrumb.uppercased())
                    .font(.hud(.caption, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(HUD.cyan.opacity(0.8))
                Text(title.uppercased())
                    .font(.hud(.largeTitle, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(HUD.text)
                    .shadow(color: HUD.cyan.opacity(0.35), radius: 10)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// A labeled input row styled for HUD forms.
struct HUDField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.hud(.caption2, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(HUD.dim)
            content()
                .textFieldStyle(.plain)
                .font(.hud(.body))
                .foregroundStyle(HUD.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(HUD.void.opacity(0.7), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HUD.cyan.opacity(0.25), lineWidth: 1))
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(HUD.dim)
            }
        }
    }
}

extension View {
    /// Primary "commit" action styling (Liquid Glass, phosphor tint).
    func hudPrimaryButton(tint: Color = HUD.cyan) -> some View {
        self
            .foregroundStyle(HUD.void)
            .buttonStyle(.glassProminent)
            .tint(tint)
            .font(.hud(.callout, weight: .bold))
    }

    func hudSecondaryButton() -> some View {
        self
            .foregroundStyle(HUD.cyan)
            .buttonStyle(.glass)
            .font(.hud(.callout, weight: .semibold))
    }
}
