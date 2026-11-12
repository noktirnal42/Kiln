import SwiftUI

/// ⌘K. Type to filter, arrows to move, return to run, escape to close.
struct CommandPaletteView: View {
    let commands: [WorkstationCommand]
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    /// Where the pointer last was. A row takes the highlight only when the pointer really moved, so a list
    /// that reorders or scrolls under a resting pointer cannot steal it from the top result.
    @State private var lastPointer: CGPoint?
    @FocusState private var searchFocused: Bool

    private var results: [WorkstationCommand] { CommandRanking.rank(commands, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SSSpacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command or where to go…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                Button(action: dismiss) { SSKeyCap("esc") }
                    .buttonStyle(.plain)
                    .help("Close (esc)")
                    .accessibilityLabel("Close command palette")
            }
            .padding(SSSpacing.m)
            Divider()
            if results.isEmpty {
                VStack(spacing: 4) {
                    Text("Nothing matches “\(query)”.").font(SSTypography.body())
                    Text("Try an activity name, an action such as “build”, or a tool name such as “re_”.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(SSSpacing.l)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                Button { run(command) } label: { row(command, selected: index == selection) }
                                    .buttonStyle(.plain)
                                    .id(command.id)
                                    .onContinuousHover(coordinateSpace: .named("paletteList")) { phase in
                                        if case .active(let point) = phase, point != lastPointer { lastPointer = point; selection = index }
                                    }
                                    .accessibilityLabel("\(command.title). \(command.subtitle)")
                            }
                        }
                        .padding(SSSpacing.xs)
                    }
                    .coordinateSpace(name: "paletteList")
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, new in
                        if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: SSCornerRadius.large))
        .overlay(RoundedRectangle(cornerRadius: SSCornerRadius.large).strokeBorder(SSColor.hairline))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { searchFocused = true }
        .accessibilityAddTraits(.isModal)
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ command: WorkstationCommand, selected: Bool) -> some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: command.symbol)
                .frame(width: 22)
                .foregroundStyle(selected ? SSColor.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(SSTypography.body())
                Text(command.subtitle).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let shortcut = command.shortcut { SSKeyCap(shortcut) }
        }
        .padding(.horizontal, SSSpacing.s)
        .padding(.vertical, 6)
        .background(selected ? SSColor.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: SSCornerRadius.small))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ command: WorkstationCommand) {
        dismiss()
        command.run()
    }
}
