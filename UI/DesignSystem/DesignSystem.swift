import SwiftUI
import AppKit

public enum SSTypography {
    public static func display() -> Font {
        .system(size: 28, weight: .bold)
    }

    public static func title() -> Font {
        .system(size: 20, weight: .semibold)
    }

    public static func headline() -> Font {
        .system(size: 15, weight: .semibold)
    }

    public static func body() -> Font {
        .system(size: 13, weight: .regular)
    }

    public static func caption() -> Font {
        .system(size: 11, weight: .regular)
    }

    public static func mono(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

public enum SSSpacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 40
}

public enum SSCornerRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 16
}

extension Color {
    /// A colour that follows light/dark appearance, including in places SwiftUI does not re-evaluate it.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

public enum SSColor {
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let secondaryBackground = Color(nsColor: .underPageBackgroundColor)
    public static let controlBackground = Color(nsColor: .controlBackgroundColor)
    public static let separator = Color(nsColor: .separatorColor)
    /// Kiln's ember. The app tint and the single accent: selection, focus, the running state.
    public static let accent = ember
    public static let success = Color.green
    public static let warning = Color.orange
    public static let danger = Color.red

    // MARK: Workstation palette (warm graphite, one ember accent)

    public static let ember = Color.adaptive(
        light: NSColor(srgbRed: 0.85, green: 0.27, blue: 0.12, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.48, blue: 0.24, alpha: 1))
    /// The window canvas behind everything.
    public static let canvas = Color.adaptive(
        light: NSColor(srgbRed: 0.965, green: 0.957, blue: 0.949, alpha: 1),
        dark: NSColor(srgbRed: 0.094, green: 0.082, blue: 0.075, alpha: 1))
    /// Panels and cards sitting on the canvas.
    public static let surface = Color.adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.110, blue: 0.102, alpha: 1))
    /// Things that should read as lifted: hovered rows, selected rail items, the palette.
    public static let surfaceRaised = Color.adaptive(
        light: NSColor(srgbRed: 0.93, green: 0.92, blue: 0.91, alpha: 1),
        dark: NSColor(srgbRed: 0.173, green: 0.153, blue: 0.141, alpha: 1))
    public static let hairline = Color.adaptive(
        light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.09))
}
