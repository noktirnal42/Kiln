import Foundation

/// Turns a chat reply into something worth reading aloud: code, links and markdown punctuation are dropped or
/// shortened so the voice does not spell out symbols. Same rules as `Core/Voice/SpokenText.swift` in the Mac app.
enum SpokenText {
    static func clean(_ markdown: String) -> String {
        var text = markdown
        var hadCode = false
        func replace(_ pattern: String, with template: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        if text.contains("```") {
            hadCode = true
            replace("```[\\s\\S]*?(```|$)", with: "\n", options: [])
        }
        replace("!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1")           // images keep their alt text
        replace("\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1")             // links keep their label
        replace("https?://\\S+", with: "a link")
        replace("(?m)^\\s{0,3}#{1,6}\\s*", with: "")                 // headings
        replace("(?m)^\\s*[-*+]\\s+", with: "")                      // bullets
        replace("(?m)^\\s*\\d+[.)]\\s+", with: "")                   // numbered lists
        replace("(?m)^\\s*>\\s?", with: "")                          // quotes
        replace("(?m)^\\s*\\|?[-:| ]{3,}\\|?\\s*$", with: "")        // table rules
        replace("\\|", with: ", ")
        replace("[*_~`]+", with: "")
        replace("[ \\t]+", with: " ")
        replace("\\n{3,}", with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hadCode { text += text.isEmpty ? "The code is on screen." : " The code is on screen." }
        return text
    }

    /// Paragraph-sized pieces, so speech can start sooner and be interrupted between them.
    static func chunks(_ text: String, limit: Int = 400) -> [String] {
        var result: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= limit { result.append(trimmed); continue }
            var current = ""
            trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sentence, _, _, _ in
                guard let sentence else { return }
                if current.count + sentence.count > limit, !current.isEmpty {
                    result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                }
                current += sentence
            }
            if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        }
        return result
    }
}
