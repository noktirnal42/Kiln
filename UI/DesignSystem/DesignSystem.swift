import SwiftUI

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

public enum SSColor {
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let secondaryBackground = Color(nsColor: .underPageBackgroundColor)
    public static let controlBackground = Color(nsColor: .controlBackgroundColor)
    public static let separator = Color(nsColor: .separatorColor)
    public static let accent = Color.accentColor
    public static let success = Color.green
    public static let warning = Color.orange
    public static let danger = Color.red
}
