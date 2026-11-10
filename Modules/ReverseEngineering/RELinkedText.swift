import SwiftUI
import AxiomCore

/// What a clicked address, symbol or string inside a listing or pseudocode means. Every code view in Analyze uses it.
enum RELink: Equatable {
    case function(String)
    case address(String)
    case string(String)

    var url: URL {
        switch self {
        case .function(let a): URL(string: "kiln-re://function/\(a)")!
        case .address(let a): URL(string: "kiln-re://address/\(a)")!
        case .string(let s): URL(string: "kiln-re://string/\(s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")!
        }
    }
    init?(url: URL) {
        guard url.scheme == "kiln-re", let host = url.host else { return nil }
        let value = String(url.path.dropFirst()).removingPercentEncoding ?? ""
        switch host {
        case "function": self = .function(value)
        case "address": self = .address(value)
        case "string": self = .string(value)
        default: return nil
        }
    }
}

enum RELinkedText {
    private static let tokenPattern = try! NSRegularExpression(pattern: #"0x[0-9a-fA-F]{5,16}|\b[0-9a-fA-F]{8,16}\b|[A-Za-z_$][A-Za-z0-9_$.]*|"(?:[^"\\]|\\.)*""#)

    /// Turns every function name, address and quoted string that the index knows into a link; the rest stays plain.
    static func attributed(_ text: String, index: REXrefIndex?) -> AttributedString {
        var result = AttributedString(text)
        guard let index else { return result }
        let ns = text as NSString
        for match in tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            var link: RELink?
            if token.hasPrefix("\"") {
                let inner = String(token.dropFirst().dropLast())
                if index.strings.contains(where: { $0.value == inner }) { link = .string(inner) }
            } else if let address = index.functionNames[token] {
                link = .function(REListing.hex(address))
            } else if let value = REListing.address(token), token.hasPrefix("0x") || token.count >= 8, token.allSatisfy(\.isHexDigit) || token.hasPrefix("0x") {
                link = index.functionStarts[value] != nil ? .function(REListing.hex(value)) : .address(REListing.hex(value))
            }
            guard let link, let range = Range(match.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = link.url
            result[lower..<upper].foregroundColor = SSColor.accent
        }
        return result
    }
}

/// A selectable, scrollable code pane whose addresses, symbols and strings are links.
struct RELinkedCodeBlock: View {
    let text: String
    let index: REXrefIndex?
    let onLink: (RELink) -> Void

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(RELinkedText.attributed(text, index: index))
                .font(SSTypography.mono(11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(SSSpacing.m)
        }
        .background(SSColor.canvas)
        .environment(\.openURL, OpenURLAction { url in
            guard let link = RELink(url: url) else { return .systemAction }
            onLink(link); return .handled
        })
    }
}
