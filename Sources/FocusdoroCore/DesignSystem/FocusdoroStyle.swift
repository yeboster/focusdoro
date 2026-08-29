import SwiftUI

/// Visual language from spec §5. Dark material only in MVP; every value here is a
/// token so a future light mode is a palette swap rather than a view rewrite.
public enum Theme {
    // 8pt spacing grid.
    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    public enum Radius {
        public static let popover: CGFloat = 29
        public static let card: CGFloat = 13
        public static let control: CGFloat = 11
        public static let chip: CGFloat = 10
    }

    public enum Metric {
        public static let popoverWidth: CGFloat = 460
        /// A `ScrollView` has no intrinsic height, so a list needs a floor as well as a
        /// ceiling — with only a max, SwiftUI sizes it to almost nothing.
        public static let listMinHeight: CGFloat = 340
        public static let listMaxHeight: CGFloat = 520
        /// Everything in the picker that is not the scrolling list: notch, header,
        /// search field, sort/filter row, footer, and the popover's own padding. Used to
        /// shrink the list when the screen cannot fit the full-size popover.
        public static let pickerChromeHeight: CGFloat = 250
        /// Fallback when no screen has reported its height yet.
        public static let popoverFallbackHeight: CGFloat = 700
        public static let actionHeight: CGFloat = 42
        public static let settingsRowHeight: CGFloat = 38

        /// A scrolling list is the only part of the popover that can give height back,
        /// so it absorbs whatever a short screen cannot fit. `ScrollView` has no
        /// intrinsic height, hence both a floor and a ceiling.
        public static func listCap(forPopoverHeight height: CGFloat) -> CGFloat {
            max(160, min(listMaxHeight, height - pickerChromeHeight))
        }
        public static let settingsValueWidth: CGFloat = 72
        public static let rowHeight: CGFloat = 52
        public static let progressHeight: CGFloat = 6
        public static let notchWidth: CGFloat = 34
        public static let notchHeight: CGFloat = 5
    }

    public enum Palette {
        /// Blue-black at the top, graphite toward the bottom.
        public static let surfaceTop = Color(red: 0.086, green: 0.106, blue: 0.157)
        public static let surfaceBottom = Color(red: 0.098, green: 0.102, blue: 0.114)
        public static let card = Color.white.opacity(0.055)
        public static let cardStroke = Color.white.opacity(0.075)
        public static let border = Color(red: 0.42, green: 0.50, blue: 0.62).opacity(0.28)
        public static let innerHighlight = Color.white.opacity(0.10)

        public static let accent = Color(red: 0.20, green: 0.51, blue: 0.98)
        public static let accentPressed = Color(red: 0.16, green: 0.42, blue: 0.85)
        public static let track = Color.white.opacity(0.10)

        public static let textPrimary = Color.white.opacity(0.96)
        public static let textSecondary = Color.white.opacity(0.62)
        public static let textTertiary = Color.white.opacity(0.42)
        public static let danger = Color(red: 0.98, green: 0.42, blue: 0.38)
        public static let success = Color(red: 0.35, green: 0.80, blue: 0.55)
        public static let warning = Color(red: 0.98, green: 0.75, blue: 0.32)
    }

    public enum Font {
        public static let wordmark = SwiftUI.Font.system(size: 13, weight: .semibold, design: .default)
        public static let sectionLabel = SwiftUI.Font.system(size: 10, weight: .semibold).width(.expanded)
        public static let taskTitle = SwiftUI.Font.system(size: 14, weight: .medium)
        public static let meta = SwiftUI.Font.system(size: 11, weight: .regular)
        public static let phase = SwiftUI.Font.system(size: 11, weight: .semibold)
        public static let body = SwiftUI.Font.system(size: 12, weight: .regular)
        public static let button = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let statValue = SwiftUI.Font.system(size: 17, weight: .semibold).monospacedDigit()
        public static let statLabel = SwiftUI.Font.system(size: 10, weight: .medium)

        /// Tabular numerals keep the countdown from jittering as digits change.
        public static let timer = SwiftUI.Font.system(size: 52, weight: .light, design: .rounded).monospacedDigit()
    }
}

// MARK: - Surfaces

public struct PopoverSurface: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    LinearGradient(
                        colors: [Theme.Palette.surfaceTop, Theme.Palette.surfaceBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // Inner highlight along the top edge, the way AppKit sheets read.
                    RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Theme.Palette.innerHighlight, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            }
    }
}

public struct CardSurface: ViewModifier {
    var radius: CGFloat = Theme.Radius.card

    public func body(content: Content) -> some View {
        content
            .background(Theme.Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Palette.cardStroke, lineWidth: 1)
            }
    }
}

public extension View {
    func popoverSurface() -> some View { modifier(PopoverSurface()) }
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View { modifier(CardSurface(radius: radius)) }
}

// MARK: - Buttons

/// The single blue action in the popover. Exactly one per screen (spec §5).
public struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.button)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.actionHeight)
            .background(
                configuration.isPressed ? Theme.Palette.accentPressed : Theme.Palette.accent,
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

public struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.button)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.actionHeight)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.Palette.cardStroke, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

public struct QuietButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.body)
            .foregroundStyle(configuration.isPressed ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .contentShape(Rectangle())
    }
}

// MARK: - Small shared pieces

public struct SectionLabel: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.sectionLabel)
            .tracking(0.9)
            .foregroundStyle(Theme.Palette.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Thin, high-contrast, blue. Respects Reduce Motion by skipping the fill animation.
public struct ProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let progress: Double

    public init(progress: Double) { self.progress = progress }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.track)
                Capsule()
                    .fill(Theme.Palette.accent)
                    .frame(width: max(0, min(1, progress)) * proxy.size.width)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
            }
        }
        .frame(height: Theme.Metric.progressHeight)
        .accessibilityElement()
        .accessibilityLabel("Session progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// Small centered tab aligned to the menu-bar item, drawn inside the popover body.
public struct PopoverNotch: View {
    public init() {}

    public var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.18))
            .frame(width: Theme.Metric.notchWidth, height: Theme.Metric.notchHeight)
            .accessibilityHidden(true)
    }
}
