import Foundation

/// Parses RFC 5322 / MIME messages: headers (unfolded, RFC 2047 words decoded), addresses, multipart bodies, base64 and quoted-printable.
public enum MIMEParser {
    public static func parse(_ raw: Data) -> MailMessage {
        let entity = Entity(raw: raw)
        var message = MailMessage()
        message.headers = entity.headers
        message.messageID = entity.headers["message-id"].flatMap(firstID)
        message.inReplyTo = entity.headers["in-reply-to"].flatMap(firstID)
        message.references = entity.headers["references"].map(allIDs) ?? []
        message.from = addresses(entity.headers["from"] ?? "")
        message.to = addresses(entity.headers["to"] ?? "")
        message.cc = addresses(entity.headers["cc"] ?? "")
        message.subject = decodeWords(entity.headers["subject"] ?? "")
        message.date = entity.headers["date"].flatMap(parseDate)
        collect(entity, into: &message)
        return message
    }

    // MARK: Entities

    struct Entity {
        var headers: [String: String] = [:]
        var body = Data()
        init(raw: Data) {
            let (head, body) = split(raw)
            self.body = body
            var lines: [String] = []
            for line in (String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self)).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
                if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) }
                else { lines.append(String(line)) }
            }
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                if headers[name] == nil { headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
        }
        var contentType: (type: String, params: [String: String]) { MIMEParser.parameters(headers["content-type"] ?? "text/plain") }
    }

    /// Splits at the first blank line (CRLF or LF).
    static func split(_ raw: Data) -> (Data, Data) {
        for pattern in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
            if let range = raw.range(of: pattern) { return (raw[raw.startIndex..<range.lowerBound], raw[range.upperBound...]) }
        }
        return (raw, Data())
    }

    private static func collect(_ entity: Entity, into message: inout MailMessage) {
        let (type, params) = entity.contentType
        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in multipartParts(entity.body, boundary: boundary) { collect(Entity(raw: part), into: &message) }
            return
        }
        let decoded = decodeBody(entity.body, encoding: entity.headers["content-transfer-encoding"])
        let disposition = parameters(entity.headers["content-disposition"] ?? "")
        let filename = disposition.params["filename"].map(decodeWords) ?? params["name"].map(decodeWords)
        if disposition.type == "attachment" || (filename != nil && type != "text/plain" && type != "text/html") {
            message.attachments.append(MailAttachment(filename: filename ?? "attachment", contentType: type, data: decoded))
        } else if type == "text/html" {
            if message.html == nil { message.html = string(decoded, charset: params["charset"]) }
        } else if type == "text/plain" || type.isEmpty {
            if message.plainText == nil { message.plainText = string(decoded, charset: params["charset"]) }
        }
    }

    static func multipartParts(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var cursor = body.startIndex
        var starts: [Data.Index] = []
        while let range = body.range(of: delimiter, in: cursor..<body.endIndex) {
            starts.append(range.lowerBound)
            cursor = range.upperBound
        }
        for (i, start) in starts.enumerated() {
            let afterDelimiter = start + delimiter.count
            if body[afterDelimiter...].starts(with: Data("--".utf8)) { break }
            var contentStart = afterDelimiter
            if body[contentStart...].starts(with: Data("\r\n".utf8)) { contentStart += 2 } else if body[contentStart...].starts(with: Data("\n".utf8)) { contentStart += 1 }
            var end = i + 1 < starts.count ? starts[i + 1] : body.endIndex
            if end - 2 >= contentStart, body[(end - 2)..<end] == Data("\r\n".utf8) { end -= 2 } else if end - 1 >= contentStart, body[end - 1] == 0x0A { end -= 1 }
            if contentStart <= end { parts.append(body[contentStart..<end]) }
        }
        return parts
    }

    // MARK: Header values

    /// "text/plain; charset=utf-8" -> ("text/plain", ["charset": "utf-8"]). Handles quoted values and RFC 2231 `filename*=utf-8''name`.
    static func parameters(_ value: String) -> (type: String, params: [String: String]) {
        let pieces = splitUnquoted(value, on: ";")
        let type = (pieces.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            if key.hasSuffix("*") {
                key.removeLast()
                let bits = val.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if bits.count == 3 { val = String(bits[2]).removingPercentEncoding ?? String(bits[2]) }
            }
            params[key] = val
        }
        return (type, params)
    }

    static func splitUnquoted(_ s: String, on separator: Character) -> [String] {
        var out: [String] = [], current = "", quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); current.append(ch) }
            else if ch == separator, !quoted { out.append(current); current = "" }
            else { current.append(ch) }
        }
        out.append(current)
        return out
    }

    public static func addresses(_ value: String) -> [MailAddress] {
        splitUnquoted(value, on: ",").compactMap { raw in
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            if let open = item.lastIndex(of: "<"), let close = item.lastIndex(of: ">"), open < close {
                let email = String(item[item.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                var name = item[..<open].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                let decoded = decodeWords(name)
                return email.contains("@") ? MailAddress(name: decoded.isEmpty ? nil : decoded, email: email) : nil
            }
            return item.contains("@") ? MailAddress(email: item) : nil
        }
    }

    static func firstID(_ value: String) -> String? { allIDs(value).first }
    static func allIDs(_ value: String) -> [String] {
        var ids: [String] = [], current: String?
        for ch in value {
            if ch == "<" { current = "" }
            else if ch == ">", let id = current { if !id.isEmpty { ids.append(id) }; current = nil }
            else if current != nil { current?.append(ch) }
        }
        return ids
    }

    static func parseDate(_ value: String) -> Date? {
        let cleaned = value.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    // MARK: Encodings

    /// RFC 2047 encoded words: =?utf-8?B?...?= and =?iso-8859-1?Q?...?=
    public static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let regex = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)
        let ns = value as NSString
        var result = "", last = 0, previousWasWord = false
        for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            if !(previousWasWord && gap.trimmingCharacters(in: .whitespaces).isEmpty) { result += gap }
            let charset = ns.substring(with: match.range(at: 1)), enc = ns.substring(with: match.range(at: 2)).uppercased(), text = ns.substring(with: match.range(at: 3))
            let data: Data? = enc == "B" ? Data(base64Encoded: text) : decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " "), headerMode: true)
            result += data.map { string($0, charset: charset) } ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
            previousWasWord = true
        }
        result += ns.substring(from: last)
        return result
    }

    static func decodeBody(_ body: Data, encoding: String?) -> Data {
        switch encoding?.lowercased() {
        case "base64":
            let text = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: text) ?? Data()
        case "quoted-printable": return decodeQuotedPrintable(String(decoding: body, as: UTF8.self), headerMode: false)
        default: return body
        }
    }

    static func decodeQuotedPrintable(_ text: String, headerMode: Bool) -> Data {
        var out = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "="), i + 1 < bytes.count {
                if bytes[i + 1] == 0x0A { i += 2; continue }
                if bytes[i + 1] == 0x0D, i + 2 < bytes.count, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) { out.append(UInt8(hi << 4 | lo)); i += 3; continue }
            }
            out.append(b); i += 1
        }
        return out
    }
    private static func hex(_ b: UInt8) -> Int? {
        switch b { case 48...57: Int(b) - 48; case 65...70: Int(b) - 55; case 97...102: Int(b) - 87; default: nil }
    }

    static func string(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased()
        let encoding: String.Encoding = switch name {
        case "iso-8859-1", "latin1", "iso8859-1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        case "us-ascii", "ascii": .ascii
        case "utf-16": .utf16
        default: .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }
}
