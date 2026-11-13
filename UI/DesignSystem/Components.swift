import SwiftUI

// Shared building blocks for the workstation shell. Kept small and boring on purpose: a panel, a
// badge, a status dot, a key cap, an empty state. Everything else composes these.

struct SSPanelModifier: ViewModifier {
    var padding: CGFloat = SSSpacing.m
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(SSColor.surface, in: RoundedRectangle(cornerRadius: SSCornerRadius.medium))
            .overlay(RoundedRectangle(cornerRadius: SSCornerRadius.medium).strokeBorder(SSColor.hairline))
    }
}

extension View {
    /// A card on the canvas: surface fill, hairline border, medium radius.
    func ssPanel(padding: CGFloat = SSSpacing.m) -> some View { modifier(SSPanelModifier(padding: padding)) }
}

/// Small uppercase section label.
struct SSSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(ThemeRuntime.font(10, .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct SSBadge: View {
    let text: String
    var tint: Color = SSColor.accent
    var body: some View {
        Text(text)
            .font(ThemeRuntime.font(10, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A small coloured dot with an optional pulse for "something is happening".
struct SSStatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? (on ? 1 : 0.35) : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

/// A keyboard hint such as ⌘K.
struct SSKeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SSEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: SSSpacing.s) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(SSTypography.headline())
            Text(message).font(SSTypography.caption()).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(SSSpacing.l)
        // Fills the pane it stands in for. Without the height, a pane whose only content is an empty state
        // shrinks to its text and the stack around it centres, pushing the activity header down the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Icon-only button with a hover highlight, for rails and toolbars.
struct SSIconButtonStyle: ButtonStyle {
    var selected = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? SSColor.accent : (hovering ? Color.primary : Color.secondary))
            .background(
                RoundedRectangle(cornerRadius: SSCornerRadius.small)
                    .fill(selected ? SSColor.accent.opacity(0.14) : (hovering ? SSColor.surfaceRaised : .clear))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}
