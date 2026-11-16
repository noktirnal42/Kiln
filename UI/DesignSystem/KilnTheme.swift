import SwiftUI
import AppKit

/// Colours for one appearance (light or dark) of a theme, as `#RRGGBB`. Hairlines are derived (white or black at low opacity).
public struct ThemePalette: Codable, Equatable, Sendable {
    public var accent: String
    public var canvas: String
    public var surface: String
    public var surfaceRaised: String
    public init(accent: String, canvas: String, surface: String, surfaceRaised: String) {
        self.accent = accent; self.canvas = canvas; self.surface = surface; self.surfaceRaised = surfaceRaised
    }
}

public enum ThemeFontDesign: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, rounded, serif, monospaced
    public var id: String { rawValue }
    public var label: String { switch self { case .standard: "System"; case .rounded: "Rounded"; case .serif: "Serif"; case .monospaced: "Monospaced" } }
    var design: Font.Design { switch self { case .standard: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced } }
}

/// A complete look: colours for light and dark, a font design and a text size multiplier. Built-in themes cannot be edited; duplicate one to customize it.
public struct KilnTheme: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public var light: ThemePalette
    public var dark: ThemePalette
    public var fontDesign: ThemeFontDesign
    /// 0.85...1.4, applied to the design-system text sizes.
    public var fontScale: Double

    public init(id: String = UUID().uuidString, name: String, builtIn: Bool = false, light: ThemePalette, dark: ThemePalette,
                fontDesign: ThemeFontDesign = .standard, fontScale: Double = 1.0) {
        self.id = id; self.name = name; self.builtIn = builtIn; self.light = light; self.dark = dark
        self.fontDesign = fontDesign; self.fontScale = min(1.4, max(0.85, fontScale))
    }
}

public enum KilnThemes {
    public static let defaultID = "ember"

    public static let presets: [KilnTheme] = [
        KilnTheme(id: "ember", name: "Ember", builtIn: true,
                  light: ThemePalette(accent: "#D9451F", canvas: "#F6F4F2", surface: "#FFFFFF", surfaceRaised: "#EDEBE8"),
                  dark: ThemePalette(accent: "#FF7A3D", canvas: "#181513", surface: "#201C1A", surfaceRaised: "#2C2724")),
        KilnTheme(id: "midnight", name: "Midnight", builtIn: true,
                  light: ThemePalette(accent: "#2563EB", canvas: "#F3F6FB", surface: "#FFFFFF", surfaceRaised: "#E6ECF6"),
                  dark: ThemePalette(accent: "#6AA9FF", canvas: "#0B1020", surface: "#121A2E", surfaceRaised: "#1C2742")),
        KilnTheme(id: "forest", name: "Forest", builtIn: true,
                  light: ThemePalette(accent: "#1E8A55", canvas: "#F3F7F4", surface: "#FFFFFF", surfaceRaised: "#E5EEE8"),
                  dark: ThemePalette(accent: "#5CC48A", canvas: "#0D1511", surface: "#121D17", surfaceRaised: "#1B2B22")),
        KilnTheme(id: "violet", name: "Violet", builtIn: true,
                  light: ThemePalette(accent: "#6D3FD1", canvas: "#F6F3FA", surface: "#FFFFFF", surfaceRaised: "#EBE5F4"),
                  dark: ThemePalette(accent: "#B794F6", canvas: "#120F1C", surface: "#1A1628", surfaceRaised: "#262038")),
        KilnTheme(id: "rose", name: "Rose", builtIn: true,
                  light: ThemePalette(accent: "#DB2777", canvas: "#FBF3F6", surface: "#FFFFFF", surfaceRaised: "#F3E3EA"),
                  dark: ThemePalette(accent: "#F472B6", canvas: "#1A0F14", surface: "#23151C", surfaceRaised: "#321F29"), fontDesign: .rounded),
        KilnTheme(id: "graphite", name: "Graphite", builtIn: true,
                  light: ThemePalette(accent: "#374151", canvas: "#F5F5F5", surface: "#FFFFFF", surfaceRaised: "#E8E8E8"),
                  dark: ThemePalette(accent: "#9AA4B2", canvas: "#111111", surface: "#181818", surfaceRaised: "#242424"), fontDesign: .monospaced),
        KilnTheme(id: "paper", name: "Paper", builtIn: true,
                  light: ThemePalette(accent: "#B45309", canvas: "#F7F1E3", surface: "#FFFCF2", surfaceRaised: "#EBE2CC"),
                  dark: ThemePalette(accent: "#E0A458", canvas: "#1B1814", surface: "#23201A", surfaceRaised: "#2F2A22"), fontDesign: .serif),
    ]

    public static func preset(_ id: String) -> KilnTheme { presets.first { $0.id == id } ?? presets[0] }
}

// MARK: Hex colours

public enum HexColor {
    /// `#RRGGBB` (the `#` is optional); nil for anything else.
    public static func parse(_ text: String) -> (r: Double, g: Double, b: Double)? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
    public static func nsColor(_ hex: String, fallback: NSColor = .gray) -> NSColor {
        guard let c = parse(hex) else { return fallback }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    public static func string(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }
}

/// The active theme, readable from any thread: dynamic colours resolve it at draw time, so a change shows on the next redraw.
public final class ThemeRuntime: @unchecked Sendable {
    public static let shared = ThemeRuntime()
    private let lock = NSLock()
    private var theme = KilnThemes.presets[0]
    public var current: KilnTheme { lock.lock(); defer { lock.unlock() }; return theme }
    public func set(_ new: KilnTheme) { lock.lock(); theme = new; lock.unlock() }

    /// A system font in the theme's design and scale.
    public static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let theme = shared.current
        return .system(size: (size * theme.fontScale).rounded(), weight: weight, design: theme.fontDesign.design)
    }

    /// A colour that follows light/dark and reads the active theme when it is resolved.
    static func color(_ pick: @escaping @Sendable (ThemePalette) -> String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let theme = shared.current
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return HexColor.nsColor(pick(dark ? theme.dark : theme.light))
        })
    }
}

/// The saved custom themes and the selected one. Persisted as JSON in UserDefaults (pass a suite name in tests).
@MainActor @Observable public final class ThemeStore {
    public private(set) var custom: [KilnTheme] = []
    public private(set) var selectedID = KilnThemes.defaultID
    /// Bumped on every change so the window can redraw with the new look.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    private static let customKey = "ui.themes.custom", selectedKey = "ui.themes.selected"

    public init(suiteName: String? = nil) {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        if let data = defaults.data(forKey: Self.customKey), let saved = try? JSONDecoder().decode([KilnTheme].self, from: data) {
            custom = saved.map { var t = $0; t.builtIn = false; return t }
        }
        selectedID = defaults.string(forKey: Self.selectedKey) ?? KilnThemes.defaultID
        if !all.contains(where: { $0.id == selectedID }) { selectedID = KilnThemes.defaultID }
        ThemeRuntime.shared.set(selected)
    }

    public var all: [KilnTheme] { KilnThemes.presets + custom }
    public var selected: KilnTheme { all.first { $0.id == selectedID } ?? KilnThemes.presets[0] }

    public func select(_ id: String) {
        guard all.contains(where: { $0.id == id }) else { return }
        selectedID = id; defaults.set(id, forKey: Self.selectedKey); applied()
    }

    /// Copies any theme into a new editable custom theme and selects it.
    @discardableResult public func duplicate(_ id: String) -> KilnTheme? {
        guard let source = all.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID().uuidString; copy.builtIn = false
        copy.name = uniqueName("\(source.name) copy")
        custom.append(copy); persist(); select(copy.id)
        return copy
    }

    /// Saves changes to a custom theme (built-in themes are ignored).
    public func update(_ theme: KilnTheme) {
        guard let index = custom.firstIndex(where: { $0.id == theme.id }) else { return }
        var t = theme; t.builtIn = false; t.fontScale = min(1.4, max(0.85, t.fontScale))
        if t.name.trimmingCharacters(in: .whitespaces).isEmpty { t.name = custom[index].name }
        custom[index] = t; persist()
        if selectedID == t.id { applied() }
    }

    public func delete(_ id: String) {
        guard custom.contains(where: { $0.id == id }) else { return }
        custom.removeAll { $0.id == id }; persist()
        if selectedID == id { select(KilnThemes.defaultID) } else { revision += 1 }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(all.map(\.name))
        if !names.contains(base) { return base }
        var n = 2; while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
    private func persist() { if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Self.customKey) } }
    private func applied() { ThemeRuntime.shared.set(selected); revision += 1 }
}
