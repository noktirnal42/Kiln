import SwiftUI
import AppKit

public enum SSTypography {
    public static func display() -> Font {
        ThemeRuntime.font(28, .bold)
    }

    public static func title() -> Font {
        ThemeRuntime.font(20, .semibold)
    }

    public static func headline() -> Font {
        ThemeRuntime.font(15, .semibold)
    }

    public static func body() -> Font {
        ThemeRuntime.font(13, .regular)
    }

    public static func caption() -> Font {
        ThemeRuntime.font(11, .regular)
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

    public static let ember = ThemeRuntime.color { $0.accent }
    /// The window canvas behind everything.
    public static let canvas = ThemeRuntime.color { $0.canvas }
    /// Panels and cards sitting on the canvas.
    public static let surface = ThemeRuntime.color { $0.surface }
    /// Things that should read as lifted: hovered rows, selected rail items, the palette.
    public static let surfaceRaised = ThemeRuntime.color { $0.surfaceRaised }
    public static let hairline = Color.adaptive(
        light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.09))
}
