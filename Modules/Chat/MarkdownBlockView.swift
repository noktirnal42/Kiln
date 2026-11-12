import SwiftUI
import AppKit

struct MarkdownBlockView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            ForEach(Array(MarkdownRenderer.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownRenderer.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level <= 1 ? SSTypography.title() : level == 2 ? SSTypography.headline() : .system(size: 13, weight: .semibold))

        case .paragraph(let text):
            Text(inline(text))

        case .codeFence(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                CodeBlockHeader(language: language, code: code)
                CodeSpanView(spans: CodeHighlighter.highlight(code, language: language))
                    .padding(SSSpacing.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: SSCornerRadius.small)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: SSCornerRadius.small))

        case .listItem(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: SSSpacing.xs) {
                Text(number.map { "\($0)." } ?? "•")
                    .foregroundStyle(.secondary)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: SSSpacing.s) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }

        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(header, id: \.self) { column in
                        Text(inline(column))
                            .font(SSTypography.caption().weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            .padding(.horizontal, SSSpacing.xs)
                    }
                }
                .background(Color.secondary.opacity(0.08))
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(SSTypography.caption())
                                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                                .padding(.horizontal, SSSpacing.xs)
                        }
                    }
                    .background(index % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: SSCornerRadius.small).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: SSCornerRadius.small))

        case .divider:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

struct CodeSpanView: View {
    let spans: [CodeHighlighter.Span]

    var body: some View {
        Text(attributed)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for span in spans {
            var text = AttributedString(span.text)
            switch span.kind {
            case .keyword:
                text.foregroundColor = .pink
                text.font = .system(size: 12, design: .monospaced).weight(.semibold)
            case .string:
                text.foregroundColor = .orange
            case .comment:
                text.foregroundColor = .gray
                text.font = .system(size: 12, design: .monospaced).italic()
            case .number:
                text.foregroundColor = .teal
            case .type:
                text.foregroundColor = .indigo
            case .function:
                text.foregroundColor = .blue
            case .plain:
                break
            }
            result += text
        }
        return result
    }
}

/// The strip above a code block: the language on the left, Copy on the right (it says "Copied" for a moment).
struct CodeBlockHeader: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: SSSpacing.xs) {
            Text(language ?? "code").font(SSTypography.caption()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(SSTypography.caption())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? SSColor.success : Color.secondary)
            .help("Copy this code")
            .accessibilityLabel("Copy code")
        }
        .padding(.horizontal, SSSpacing.s).padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: SSCornerRadius.small, topTrailingRadius: SSCornerRadius.small))
    }
}
