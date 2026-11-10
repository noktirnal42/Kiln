import Foundation
import AxiomCore

/// Findings report with evidence: the binary's identity, each finding with the function listing and pseudocode that support it,
/// the analyst's renames and comments, patches, and screenshots. Written as Markdown and a self-contained HTML page.
public enum REReport {
    public struct Result: Sendable { public let folder: URL; public let markdown: URL; public let html: URL }

    public static func markdown(analysis: Analysis, workspace: REWorkspace, title: String? = nil, now: Date = Date()) -> String {
        let name = URL(fileURLWithPath: analysis.binaryPath).lastPathComponent
        var out = "# \(title ?? "Analysis report: \(name)")\n\n"
        out += "| | |\n|---|---|\n| File | `\(name)` |\n| SHA-256 | `\(analysis.sha256)` |\n| Size | \(analysis.size) bytes |\n| Format | \(analysis.format) |\n"
        out += "| Engine | \(analysis.engine) |\n| Functions | \(analysis.functions.count) |\n| Strings | \(analysis.strings.count) |\n| Generated | \(ISO8601DateFormatter().string(from: now)) |\n\n"
        let order: [REFinding.Severity] = [.critical, .high, .medium, .low, .info]
        let findings = workspace.findings.sorted { (order.firstIndex(of: $0.severity) ?? 9, $0.created) < (order.firstIndex(of: $1.severity) ?? 9, $1.created) }
        out += "## Findings (\(findings.count))\n\n"
        if findings.isEmpty { out += "_No findings recorded._\n\n" }
        for (index, finding) in findings.enumerated() {
            out += "### \(index + 1). \(finding.title)  \n**Severity:** \(finding.severity.rawValue)"
            if let address = finding.address { out += " · **Address:** `0x\(ProjectStore.normalizedAddress(address))`" }
            if let function = finding.function { out += " · **Function:** `\(function)`" }
            out += "\n\n\(finding.summary)\n\n"
            for line in finding.evidence { out += "```\n\(line)\n```\n\n" }
            if let function = analysis.functions.first(where: { $0.name == finding.function || (finding.address != nil && ProjectStore.normalizedAddress($0.address) == ProjectStore.normalizedAddress(finding.address!)) }) {
                if !function.code.isEmpty { out += "Pseudocode of `\(function.name)`:\n\n```c\n\(excerpt(function.code, 60))\n```\n\n" }
                else if !function.assembly.isEmpty { out += "Listing of `\(function.name)`:\n\n```\n\(excerpt(function.assembly, 40))\n```\n\n" }
            }
            for file in finding.attachments { out += "![\(file)](attachments/\(file))\n\n" }
        }
        let renamed = analysis.functions.filter { $0.engineName != nil && $0.name != $0.engineName }
        if !renamed.isEmpty || !(analysis.addressComments ?? [:]).isEmpty || analysis.functions.contains(where: { !$0.comment.isEmpty }) {
            out += "## Analyst annotations\n\n"
            for function in renamed { out += "- `0x\(ProjectStore.normalizedAddress(function.address))` \(function.engineName ?? "") → **\(function.name)**\n" }
            for function in analysis.functions where !function.comment.isEmpty { out += "- `\(function.name)`: \(function.comment)\n" }
            for (address, comment) in (analysis.addressComments ?? [:]).sorted(by: { $0.key < $1.key }) { out += "- `0x\(address)`: \(comment)\n" }
            out += "\n"
        }
        if !workspace.structures.isEmpty {
            out += "## Data types\n\n"
            for structure in workspace.structures { out += "```c\n\(structure.declaration)\n```\n\n" }
        }
        if !workspace.patches.isEmpty {
            out += "## Patches (applied to copies only)\n\n| Address | Original | Patched | Note |\n|---|---|---|---|\n"
            for patch in workspace.patches { out += "| `0x\(patch.address)` | `\(patch.original)` | `\(patch.bytes)` | \(patch.note) |\n" }
            out += "\n"
        }
        if !workspace.bookmarks.isEmpty {
            out += "## Bookmarks\n\n"
            for bookmark in workspace.bookmarks { out += "- `0x\(bookmark.address)` \(bookmark.note)\n" }
            out += "\n"
        }
        if !analysis.warnings.isEmpty { out += "## Engine warnings\n\n" + analysis.warnings.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return out
    }

    static func excerpt(_ text: String, _ lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.count <= lines ? text : all.prefix(lines).joined(separator: "\n") + "\n… (\(all.count - lines) more lines)"
    }

    /// Writes `report.md`, `report.html` and the attachments the findings reference into a new folder under `destination`.
    public static func export(analysis: Analysis, workspace: REWorkspace, projectFolder: URL, destination: URL, title: String? = nil) throws -> Result {
        let folder = destination.appendingPathComponent("kiln-report-" + String(analysis.sha256.prefix(8)) + "-" + String(Int(Date().timeIntervalSince1970)), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let attachments = folder.appendingPathComponent("attachments", isDirectory: true)
        for file in workspace.findings.flatMap(\.attachments) {
            let leaf = URL(fileURLWithPath: file).lastPathComponent
            let source = REWorkspaceStore.attachmentsFolder(projectFolder).appendingPathComponent(leaf)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: attachments.appendingPathComponent(leaf))
            try FileManager.default.copyItem(at: source, to: attachments.appendingPathComponent(leaf))
        }
        let text = markdown(analysis: analysis, workspace: workspace, title: title)
        let mdURL = folder.appendingPathComponent("report.md"), htmlURL = folder.appendingPathComponent("report.html")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        try html(fromMarkdown: text, title: title ?? "Analysis report").write(to: htmlURL, atomically: true, encoding: .utf8)
        return Result(folder: folder, markdown: mdURL, html: htmlURL)
    }

    /// A small Markdown renderer for exactly the constructs `markdown(...)` emits (headings, tables, fences, bullets, images).
    static func html(fromMarkdown text: String, title: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        func inline(_ s: String) -> String {
            var r = esc(s)
            r = r.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)]*)\)"#, with: "<img alt=\"$1\" src=\"$2\" style=\"max-width:100%\">", options: .regularExpression)
            r = r.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
            r = r.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
            return r
        }
        var body = ""; var inFence = false; var inTable = false; var inList = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") { body += inFence ? "</pre>\n" : "<pre>"; inFence.toggle(); continue }
            if inFence { body += esc(line) + "\n"; continue }
            if inList, !line.hasPrefix("- ") { body += "</ul>\n"; inList = false }
            if inTable, !line.hasPrefix("|") { body += "</table>\n"; inTable = false }
            if line.hasPrefix("### ") { body += "<h3>\(inline(String(line.dropFirst(4))))</h3>\n" }
            else if line.hasPrefix("## ") { body += "<h2>\(inline(String(line.dropFirst(3))))</h2>\n" }
            else if line.hasPrefix("# ") { body += "<h1>\(inline(String(line.dropFirst(2))))</h1>\n" }
            else if line.hasPrefix("|") {
                if line.contains("|---") { continue }
                if !inTable { body += "<table>\n"; inTable = true }
                body += "<tr>" + line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { "<td>\(inline($0.trimmingCharacters(in: .whitespaces)))</td>" }.joined() + "</tr>\n"
            } else if line.hasPrefix("- ") { if !inList { body += "<ul>\n"; inList = true }; body += "<li>\(inline(String(line.dropFirst(2))))</li>\n" }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { body += "<p>\(inline(line))</p>\n" }
        }
        if inTable { body += "</table>\n" }; if inList { body += "</ul>\n" }
        let style = "body{font:14px -apple-system,sans-serif;max-width:900px;margin:2em auto;padding:0 1em;color:#222}h1,h2{border-bottom:2px solid #e8622c;padding-bottom:.2em}pre{background:#f6f2ee;padding:10px;overflow:auto;border-left:3px solid #e8622c}code{font-family:Menlo,monospace;background:#f6f2ee;padding:0 3px}table{border-collapse:collapse}td{border:1px solid #ddd;padding:4px 8px}"
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(esc(title))</title><style>\(style)</style></head><body>\n\(body)</body></html>\n"
    }
}
