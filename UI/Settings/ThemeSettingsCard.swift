import SwiftUI

/// Pick a theme, or make your own: duplicate any theme, then change its colours, font and text size. Custom themes are saved on this Mac.
struct ThemeSettingsCard: View {
    @Environment(AppModel.self) private var app
    @State private var editingDark = true
    @State private var confirmDelete = false

    private var store: ThemeStore { app.themeManager.themes }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("Theme").font(SSTypography.headline())
            Text("Colours and text for the whole app. Light, Dark and High Contrast above still choose the brightness.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: SSSpacing.s)], alignment: .leading, spacing: SSSpacing.s) {
                ForEach(store.all) { theme in swatch(theme) }
            }
            HStack {
                Button("Duplicate to customize") { store.duplicate(store.selectedID); editingDark = isDarkNow }
                if !store.selected.builtIn { Button("Delete theme", role: .destructive) { confirmDelete = true } }
            }
            if !store.selected.builtIn { editor(store.selected) }
            else { Text("Built-in themes cannot be changed. Duplicate one to make it your own.").font(SSTypography.caption()).foregroundStyle(.secondary) }
        }
        .padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading).ssPanel()
        .alert("Delete \(store.selected.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(store.selectedID) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the saved theme from this Mac. Kiln switches back to Ember.") }
    }

    private var isDarkNow: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func swatch(_ theme: KilnTheme) -> some View {
        let palette = isDarkNow ? theme.dark : theme.light
        let selected = store.selectedID == theme.id
        return Button { store.select(theme.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Rectangle().fill(Color(nsColor: HexColor.nsColor(palette.canvas)))
                    Rectangle().fill(Color(nsColor: HexColor.nsColor(palette.surface)))
                    Rectangle().fill(Color(nsColor: HexColor.nsColor(palette.surfaceRaised)))
                    Rectangle().fill(Color(nsColor: HexColor.nsColor(palette.accent)))
                }
                .frame(height: 26).clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 4) {
                    Text(theme.name).font(SSTypography.caption()).lineLimit(1)
                    if !theme.builtIn { Image(systemName: "person.crop.circle").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(SSColor.accent) }
                }
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? SSColor.accent : SSColor.hairline, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme" + (selected ? ", selected" : ""))
    }

    private func editor(_ theme: KilnTheme) -> some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Divider()
            TextField("Theme name", text: binding(theme, \.name)).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            Picker("Editing", selection: $editingDark) { Text("Dark colours").tag(true); Text("Light colours").tag(false) }
                .pickerStyle(.segmented).fixedSize()
            Grid(alignment: .leading, horizontalSpacing: SSSpacing.m, verticalSpacing: SSSpacing.xs) {
                colorRow("Accent", theme, \.accent)
                colorRow("Background", theme, \.canvas)
                colorRow("Panels", theme, \.surface)
                colorRow("Raised", theme, \.surfaceRaised)
            }
            Picker("Font", selection: binding(theme, \.fontDesign)) { ForEach(ThemeFontDesign.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).fixedSize()
            HStack {
                Text("Text size")
                Slider(value: binding(theme, \.fontScale), in: 0.85...1.4).frame(width: 180)
                Text("\(Int((theme.fontScale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Font and text size apply to most text; icons and a few views keep their own sizes. Changes are saved as you make them, and the window redraws.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
        }
    }

    private func colorRow(_ label: String, _ theme: KilnTheme, _ key: WritableKeyPath<ThemePalette, String>) -> some View {
        GridRow {
            Text(label)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: HexColor.nsColor((editingDark ? theme.dark : theme.light)[keyPath: key])) },
                set: { new in
                    var t = theme
                    if editingDark { t.dark[keyPath: key] = HexColor.string(from: new) } else { t.light[keyPath: key] = HexColor.string(from: new) }
                    store.update(t)
                }), supportsOpacity: false).labelsHidden()
        }
    }

    private func binding<V>(_ theme: KilnTheme, _ key: WritableKeyPath<KilnTheme, V>) -> Binding<V> {
        Binding(get: { theme[keyPath: key] }, set: { var t = theme; t[keyPath: key] = $0; store.update(t) })
    }
}
