import SwiftUI
import AppKit

@MainActor
@Observable
public final class ThemeManager {
    public enum Appearance: String, CaseIterable, Codable, Identifiable {
        case system
        case light
        case dark
        case highContrast

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            case .highContrast: return "High Contrast"
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            case .highContrast: return NSAppearance(named: .accessibilityHighContrastAqua)
            }
        }
    }

    public private(set) var appearance: Appearance = .system
    /// Colour and font themes (built-in and the person's own).
    public let themes = ThemeStore()
    private var settings: SettingsService?
    private let settingsKey = "ui.theme"

    public init() {}

    public func attach(settings: SettingsService) async {
        self.settings = settings
        await settings.registerDefault(settingsKey, Appearance.system.rawValue)
        let stored = await settings.get(settingsKey, as: String.self, fallback: Appearance.system.rawValue)
        apply(Appearance(rawValue: stored) ?? .system)
    }

    public func apply(_ newAppearance: Appearance) {
        appearance = newAppearance
        NSApp.appearance = newAppearance.nsAppearance
        guard let settings else { return }
        Task {
            try? await settings.set(newAppearance.rawValue, forKey: settingsKey, layer: .user)
        }
    }
}
