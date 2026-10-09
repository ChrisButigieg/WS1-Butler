import SwiftUI

/// "Tactical HUD" palette: deep-space navy surfaces with phosphor cyan as the primary
/// signal color and NATO-style status colors (green / amber / red).
/// All foreground colors keep at least 4.5:1 contrast against `HUD.void` and `HUD.panel`.
enum HUD {
    static let void = Color(red: 0.016, green: 0.035, blue: 0.063)
    static let deep = Color(red: 0.027, green: 0.075, blue: 0.125)
    static let panel = Color(red: 0.035, green: 0.075, blue: 0.122)
    static let panelRaised = Color(red: 0.055, green: 0.110, blue: 0.165)
    static let grid = Color(red: 0.070, green: 0.220, blue: 0.310)

    static let cyan = Color(red: 0.000, green: 0.898, blue: 1.000)
    static let teal = Color(red: 0.114, green: 0.914, blue: 0.714)
    static let green = Color(red: 0.224, green: 1.000, blue: 0.533)
    static let amber = Color(red: 1.000, green: 0.702, blue: 0.000)
    static let red = Color(red: 1.000, green: 0.302, blue: 0.380)

    static let text = Color(red: 0.843, green: 0.969, blue: 1.000)
    static let dim = Color(red: 0.540, green: 0.690, blue: 0.760)

    static func color(for environment: ServerEnvironment) -> Color {
        switch environment {
        case .development: green
        case .test: amber
        case .production: red
        case .other: cyan
        }
    }

    static func color(for status: TargetStatus) -> Color {
        switch status {
        case .queued: dim
        case .running: cyan
        case .awaitingReview: amber
        case .succeeded: green
        case .completedWithWarnings: amber
        case .failed: red
        case .skipped: dim
        case .cancelled: red
        }
    }

    static func color(for state: StepState) -> Color {
        switch state {
        case .pending: dim.opacity(0.25)
        case .active: cyan
        case .done: green
        case .skipped: dim.opacity(0.55)
        case .failed: red
        }
    }
}

extension Font {
    /// Monospaced, Dynamic Type–aware face used for HUD labels and telemetry.
    static func hud(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}
