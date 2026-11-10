import SwiftUI

// Shared chrome for every activity (Develop, Analyze, Lab, Swarm, Audit, and whatever comes next):
// one header row, one tab strip, one pane header, one empty state. An activity that uses these looks
// like the rest of the workstation without copying spacing numbers around.

enum SSChrome {
    /// Height of the activity header and of pane headers inside an activity.
    static let headerHeight: CGFloat = 40
    static let paneHeaderHeight: CGFloat = 28
}

/// The top row of an activity: its name, optional tabs, and the actions that belong to the whole activity.
/// Never uses the window toolbar, so the title bar stays the same height on every screen.
struct SSActivityHeader<Tabs: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var tabs: () -> Tabs
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: SSSpacing.m) {
            HStack(spacing: SSSpacing.s) {
                if let symbol { Image(systemName: symbol).foregroundStyle(SSColor.accent).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(SSTypography.headline()).lineLimit(1)
            }
            .fixedSize()
            tabs()
            Spacer(minLength: 0)
            trailing().labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, SSSpacing.m)
        .frame(height: SSChrome.headerHeight)
        .background(SSColor.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(SSColor.hairline).frame(height: 1) }
        .help(subtitle ?? "")
    }
}

extension SSActivityHeader where Tabs == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tabs: { EmptyView() }, trailing: trailing)
    }
}

extension SSActivityHeader where Tabs == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tabs: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension SSActivityHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder tabs: @escaping () -> Tabs) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tabs: tabs, trailing: { EmptyView() })
    }
}

/// A row of text tabs with an ember underline on the selected one. Scrolls sideways rather than
/// truncating when the pane is narrow. Replaces the segmented pickers that clipped their last tabs.
struct SSTabStrip<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var symbol: ((Tab) -> String)?

    var body: some View {
        // Full labels when they fit; otherwise only the selected tab keeps its label and the rest
        // collapse to their icons (never truncated text, never a hidden overflow).
        // Full labels with icons when they fit; then labels alone, packed tighter (words read faster than a row of
        // icons); then only the selected tab keeps its label; then scroll. Never truncated text, never a hidden overflow.
        ViewThatFits(in: .horizontal) {
            strip(allLabels: true)
            if symbol != nil { strip(allLabels: true, icons: false) }
            if symbol != nil { strip(allLabels: false) }
            // Last resort: the compact strip, scrollable. Scrolling the full-label strip hid half the tabs off the edge.
            ScrollView(.horizontal, showsIndicators: false) { strip(allLabels: symbol == nil) }
        }
        .frame(height: SSChrome.headerHeight - 8)
    }

    private func strip(allLabels: Bool, icons: Bool = true) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 5) {
                        if let symbol, icons { Image(systemName: symbol(tab)).font(.system(size: 11)) }
                        if allLabels || selected || symbol == nil {
                            Text(title(tab)).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                        }
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, !icons ? 7 : (allLabels ? 10 : (selected ? 8 : 6))).padding(.vertical, 5)
                    .background(selected ? SSColor.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: SSCornerRadius.small))
                    .overlay(alignment: .bottom) {
                        if selected { Capsule().fill(SSColor.accent).frame(height: 2).padding(.horizontal, 8).offset(y: 3) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title(tab))
                .accessibilityLabel(title(tab))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The small header over a pane inside an activity ("Functions", "Listing", "Decompiler", "Problems").
struct SSPaneHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: SSSpacing.s) {
            SSSectionLabel(title)
            if let count { Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
            trailing().labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, SSSpacing.m)
        .frame(height: SSChrome.paneHeaderHeight)
        .background(SSColor.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(SSColor.hairline).frame(height: 1) }
    }
}

extension SSPaneHeader where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) { self.init(title: title, count: count, trailing: { EmptyView() }) }
}

/// A monospaced, selectable block of code or text on a recessed background, for listings and pseudocode.
struct SSCodeBlock: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(SSTypography.mono(11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(SSSpacing.m)
        }
        .background(SSColor.canvas)
    }
}

/// A single line status: dot, text, optional trailing content. Used for engine status and the like.
struct SSStatusLine: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            SSStatusDot(color: color)
            Text(text).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// A list beside its detail, inside an activity. Use this instead of `NavigationSplitView`: a nested split view adds a
/// window toolbar (the title bar grows and gains a second sidebar button) and dims its list like an unfocused sidebar.
struct SSMasterDetail<Master: View, Detail: View>: View {
    var masterWidth: CGFloat = 260
    @ViewBuilder var master: () -> Master
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            master()
                .frame(width: masterWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(SSColor.surface)
            Divider()
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
