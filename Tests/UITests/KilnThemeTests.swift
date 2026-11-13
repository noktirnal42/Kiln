import Foundation
import Testing
@testable import Kiln

@MainActor struct KilnThemeTests {
    @Test func everyPresetHasUniqueIDAndValidColours() {
        let presets = KilnThemes.presets
        #expect(presets.count >= 6)
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.contains { $0.id == KilnThemes.defaultID })
        for theme in presets {
            #expect(theme.builtIn)
            for palette in [theme.light, theme.dark] {
                for hex in [palette.accent, palette.canvas, palette.surface, palette.surfaceRaised] { #expect(HexColor.parse(hex) != nil, "\(theme.name) \(hex)") }
            }
        }
    }

    @Test func hexParsingAcceptsSixDigitsOnly() {
        #expect(HexColor.parse("#FF7A3D") != nil && HexColor.parse("ff7a3d") != nil)
        #expect(HexColor.parse("#FFF") == nil && HexColor.parse("zzzzzz") == nil && HexColor.parse("") == nil)
        let c = HexColor.parse("#336699")!
        #expect(abs(c.r - 0.2) < 0.001 && abs(c.g - 0.4) < 0.001 && abs(c.b - 0.6) < 0.001)
    }

    @Test func aCustomThemeIsSavedSelectedAndSurvivesARestart() {
        let suite = "KilnThemeTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ThemeStore(suiteName: suite)
        #expect(store.selectedID == KilnThemes.defaultID && store.custom.isEmpty)
        let copy = store.duplicate("midnight")!
        #expect(!copy.builtIn && copy.name == "Midnight copy" && store.selectedID == copy.id)
        var edited = copy; edited.name = "My theme"; edited.dark.accent = "#112233"; edited.fontScale = 9
        store.update(edited)
        #expect(store.selected.name == "My theme" && store.selected.dark.accent == "#112233" && store.selected.fontScale == 1.4)
        let reopened = ThemeStore(suiteName: suite)
        #expect(reopened.custom.count == 1 && reopened.selectedID == copy.id && reopened.selected.dark.accent == "#112233")
    }

    @Test func builtInThemesCannotBeEditedOrDeletedAndDuplicatesGetUniqueNames() {
        let suite = "KilnThemeTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ThemeStore(suiteName: suite)
        var hacked = KilnThemes.preset("ember"); hacked.name = "Hacked"
        store.update(hacked); store.delete("ember")
        #expect(store.all.first { $0.id == "ember" }?.name == "Ember")
        let a = store.duplicate("ember")!, b = store.duplicate("ember")!
        #expect(a.name == "Ember copy" && b.name == "Ember copy 2")
        store.delete(b.id)
        #expect(store.selectedID == KilnThemes.defaultID && store.custom.map(\.id) == [a.id])
    }

    @Test func theRuntimeFontFollowsScaleAndDesign() {
        let suite = "KilnThemeTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); ThemeRuntime.shared.set(KilnThemes.presets[0]) }
        let store = ThemeStore(suiteName: suite)
        let copy = store.duplicate("paper")!
        #expect(ThemeRuntime.shared.current.id == copy.id && ThemeRuntime.shared.current.fontDesign == .serif)
        store.select("ember")
        #expect(ThemeRuntime.shared.current.id == "ember")
    }
}
