import Foundation

/// A diagnostic reported by a language server, with 0-based positions as in the protocol.
public struct LSPDiagnostic: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var line: Int
    public var column: Int
    public var endLine: Int
    public var endColumn: Int
    public var severity: Diagnostic.Severity
    public var message: String
}

public struct LSPLocation: Equatable, Sendable {
    public var path: String
    public var line: Int
    public var column: Int
}

public struct LSPCompletion: Equatable, Sendable {
    public var label: String
    public var insertText: String
}

/// `Content-Length` framing for JSON-RPC over a pipe (the Language Server Protocol's wire format).
public struct LSPFramer: Sendable {
    private var buffer = Data()
    public init() {}

    public static func encode(_ object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// Feeds bytes and returns every complete message that is now available.
    public mutating func feed(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        let separator = Data("\r\n\r\n".utf8)
        while let range = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            guard let lengthLine = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) else {
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                continue
            }
            let bodyStart = range.upperBound
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { break }
            let body = buffer[bodyStart..<(bodyStart + length)]
            buffer = Data(buffer[(bodyStart + length)...])
            if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { messages.append(object) }
        }
        return messages
    }
}

/// A language server client over stdio: initialize, document sync, live diagnostics, go to definition and completion.
/// It speaks only what the editor uses, and degrades to "no server" when the command is missing or exits.
@MainActor @Observable
public final class LanguageServerClient {
    public enum State: Equatable, Sendable { case stopped, starting, running, failed(String) }

    public private(set) var state: State = .stopped
    public private(set) var diagnostics: [String: [LSPDiagnostic]] = [:]   // by file path

    private let command: String
    private var process: Process?
    private var input: FileHandle?
    private var framer = LSPFramer()
    private var nextID = 1
    private struct JSONBox: @unchecked Sendable { let value: Any? }
    private var pending: [Int: CheckedContinuation<JSONBox, Never>] = [:]
    private var versions: [String: Int] = [:]
    private var root: URL?

    public init(command: String = "xcrun sourcekit-lsp") {
        self.command = command
    }

    public static func serves(_ language: SyntaxHighlighter.Language) -> Bool {
        language == .swift || language == .c
    }

    public static func languageID(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": "swift"
        case "m": "objective-c"
        case "mm": "objective-cpp"
        case "cpp", "cc", "hpp": "cpp"
        default: "c"
        }
    }

    // MARK: Lifecycle

    public func start(root: URL) async {
        guard state == .stopped || { if case .failed = state { return true } else { return false } }() else { return }
        self.root = root
        signal(SIGPIPE, SIG_IGN)
        state = .starting
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = root
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processEnded() }
        }
        do { try process.run() } catch {
            state = .failed("Could not start the language server: \(error.localizedDescription)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        let result = await request("initialize", [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": root.absoluteString,
            "capabilities": [
                "textDocument": [
                    "publishDiagnostics": ["relatedInformation": false],
                    "definition": ["linkSupport": false],
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "references": [:],
                    "rename": ["prepareSupport": false],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                ],
                "workspace": ["workspaceEdit": ["documentChanges": false], "symbol": [:]],
            ],
        ], timeout: 20)
        guard result != nil else {
            state = .failed("The language server did not answer. Is Xcode installed?")
            stop()
            return
        }
        notify("initialized", [:])
        state = .running
    }

    public func stop() {
        if state == .running { notify("exit", [:]) }
        let failed: Bool = { if case .failed = state { return true } else { return false } }()
        if !failed { state = .stopped }      // a deliberate stop is not a crash
        process?.terminate()
        processEnded()
    }

    private func processEnded() {
        input = nil
        process = nil
        for (_, continuation) in pending { continuation.resume(returning: JSONBox(value: nil)) }
        pending = [:]
        versions = [:]
        if state == .running { state = .failed("The language server exited.") }
    }

    // MARK: Documents

    public func didOpen(url: URL, text: String) {
        guard state == .running else { return }
        versions[url.path] = 1
        notify("textDocument/didOpen", ["textDocument": ["uri": url.absoluteString, "languageId": Self.languageID(for: url), "version": 1, "text": text]])
    }

    public func didChange(url: URL, text: String) {
        guard state == .running, let version = versions[url.path] else { return }
        versions[url.path] = version + 1
        notify("textDocument/didChange", ["textDocument": ["uri": url.absoluteString, "version": version + 1],
                                           "contentChanges": [["text": text]]])
    }

    public func didSave(url: URL) {
        guard state == .running else { return }
        notify("textDocument/didSave", ["textDocument": ["uri": url.absoluteString]])
    }

    public func didClose(url: URL) {
        guard state == .running else { return }
        versions[url.path] = nil
        diagnostics[url.path] = nil
        notify("textDocument/didClose", ["textDocument": ["uri": url.absoluteString]])
    }

    // MARK: Queries

    public func definition(url: URL, line: Int, column: Int) async -> LSPLocation? {
        guard state == .running else { return nil }
        let result = await request("textDocument/definition", position(url, line, column), timeout: 10)
        return Self.location(from: result)
    }

    public func completions(url: URL, line: Int, column: Int) async -> [LSPCompletion] {
        guard state == .running else { return [] }
        let result = await request("textDocument/completion", position(url, line, column), timeout: 10)
        let items: [[String: Any]]
        if let list = result as? [String: Any] { items = (list["items"] as? [[String: Any]]) ?? [] }
        else { items = (result as? [[String: Any]]) ?? [] }
        return items.prefix(200).compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let edit = (item["textEdit"] as? [String: Any])?["newText"] as? String
            return LSPCompletion(label: label, insertText: (item["insertText"] as? String) ?? edit ?? label)
        }
    }

    /// The outline of one file: hierarchical when the server supports it, flat `SymbolInformation` otherwise.
    public func documentSymbols(url: URL) async -> [LSPSymbol] {
        guard state == .running else { return [] }
        let result = await request("textDocument/documentSymbol", ["textDocument": ["uri": url.absoluteString]], timeout: 15)
        return Self.symbols(from: result)
    }

    /// Every use of the symbol at a position (declaration included).
    public func references(url: URL, line: Int, column: Int) async -> [LSPLocation] {
        guard state == .running else { return [] }
        var params = position(url, line, column)
        params["context"] = ["includeDeclaration": true]
        let result = await request("textDocument/references", params, timeout: 20)
        return (result as? [[String: Any]] ?? []).compactMap { Self.location(from: $0) }
    }

    /// The edits that rename the symbol at a position everywhere; nil when the server refuses or is not running.
    public func rename(url: URL, line: Int, column: Int, to newName: String) async -> LSPWorkspaceEdit? {
        guard state == .running else { return nil }
        var params = position(url, line, column)
        params["newName"] = newName
        let result = await request("textDocument/rename", params, timeout: 30)
        return Self.workspaceEdit(from: result)
    }

    /// Documentation and type for the symbol at a position, as plain text.
    public func hover(url: URL, line: Int, column: Int) async -> String? {
        guard state == .running else { return nil }
        let result = await request("textDocument/hover", position(url, line, column), timeout: 10)
        return Self.hoverText(from: result)
    }

    /// Project-wide symbol search (⌘T style).
    public func workspaceSymbols(query: String) async -> [LSPSymbol] {
        guard state == .running else { return [] }
        let result = await request("workspace/symbol", ["query": query], timeout: 15)
        return Self.symbols(from: result)
    }

    static func symbols(from raw: Any?) -> [LSPSymbol] {
        guard let items = raw as? [[String: Any]] else { return [] }
        func point(_ range: [String: Any]?, _ key: String) -> (Int, Int)? {
            guard let p = range?[key] as? [String: Any], let l = p["line"] as? Int, let c = p["character"] as? Int else { return nil }
            return (l, c)
        }
        func convert(_ item: [String: Any]) -> LSPSymbol? {
            guard let name = item["name"] as? String else { return nil }
            let kind = LSPSymbol.Kind(rawValue: item["kind"] as? Int ?? 0) ?? .other
            if let location = item["location"] as? [String: Any] {          // SymbolInformation
                let range = location["range"] as? [String: Any]
                guard let start = point(range, "start"), let end = point(range, "end") else { return nil }
                let url = (location["uri"] as? String).flatMap { URL(string: $0) }
                return LSPSymbol(name: name, detail: item["containerName"] as? String, kind: kind, path: url?.path,
                                 line: start.0, column: start.1, endLine: end.0, children: [])
            }
            let selection = (item["selectionRange"] as? [String: Any]) ?? (item["range"] as? [String: Any])
            guard let start = point(selection, "start"), let end = point(item["range"] as? [String: Any] ?? selection, "end") else { return nil }
            let children = (item["children"] as? [[String: Any]] ?? []).compactMap(convert)
            return LSPSymbol(name: name, detail: item["detail"] as? String, kind: kind, path: nil,
                             line: start.0, column: start.1, endLine: end.0, children: children)
        }
        return items.compactMap(convert)
    }

    static func workspaceEdit(from raw: Any?) -> LSPWorkspaceEdit? {
        guard let object = raw as? [String: Any] else { return nil }
        var edits: [String: [LSPTextEdit]] = [:]
        func parse(_ list: [[String: Any]]) -> [LSPTextEdit] {
            list.compactMap { item in
                guard let range = item["range"] as? [String: Any], let s = range["start"] as? [String: Any],
                      let e = range["end"] as? [String: Any], let text = item["newText"] as? String,
                      let sl = s["line"] as? Int, let sc = s["character"] as? Int,
                      let el = e["line"] as? Int, let ec = e["character"] as? Int else { return nil }
                return LSPTextEdit(line: sl, column: sc, endLine: el, endColumn: ec, newText: text)
            }
        }
        if let changes = object["changes"] as? [String: [[String: Any]]] {
            for (uri, list) in changes {
                if let url = URL(string: uri), url.isFileURL { edits[url.path, default: []] += parse(list) }
            }
        }
        if let documentChanges = object["documentChanges"] as? [[String: Any]] {
            for change in documentChanges {
                guard let document = change["textDocument"] as? [String: Any], let uri = document["uri"] as? String,
                      let url = URL(string: uri), url.isFileURL else { continue }
                edits[url.path, default: []] += parse(change["edits"] as? [[String: Any]] ?? [])
            }
        }
        return LSPWorkspaceEdit(edits: edits)
    }

    static func hoverText(from raw: Any?) -> String? {
        guard let object = raw as? [String: Any] else { return nil }
        func text(_ contents: Any?) -> String? {
            if let string = contents as? String { return string }
            if let marked = contents as? [String: Any] { return marked["value"] as? String }
            if let list = contents as? [Any] { return list.compactMap(text).joined(separator: "\n\n") }
            return nil
        }
        let value = text(object["contents"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    private func position(_ url: URL, _ line: Int, _ column: Int) -> [String: Any] {
        ["textDocument": ["uri": url.absoluteString], "position": ["line": line, "character": column]]
    }

    static func location(from result: Any?) -> LSPLocation? {
        let first: [String: Any]?
        if let list = result as? [[String: Any]] { first = list.first } else { first = result as? [String: Any] }
        guard let first else { return nil }
        let uri = (first["uri"] as? String) ?? (first["targetUri"] as? String)
        let range = (first["range"] as? [String: Any]) ?? (first["targetSelectionRange"] as? [String: Any])
        guard let uri, let url = URL(string: uri), url.isFileURL, let start = range?["start"] as? [String: Any],
              let line = start["line"] as? Int, let column = start["character"] as? Int else { return nil }
        return LSPLocation(path: url.path, line: line, column: column)
    }

    // MARK: Wire

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async -> Any? {
        guard input != nil else { return nil }
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        // Give up after `timeout` so a stuck server never hangs the editor.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.pending.removeValue(forKey: id)?.resume(returning: JSONBox(value: nil))
        }
        let box: JSONBox = await withCheckedContinuation { continuation in pending[id] = continuation }
        return box.value
    }

    private func send(_ object: [String: Any]) {
        try? input?.write(contentsOf: LSPFramer.encode(object))
    }

    private func receive(_ data: Data) {
        for message in framer.feed(data) {
            if let id = message["id"] as? Int, message["method"] == nil {
                pending.removeValue(forKey: id)?.resume(returning: JSONBox(value: message["result"]))
            } else if let id = message["id"] as? Int, message["method"] != nil {
                // Server → client requests (registerCapability, workDoneProgress/create…): acknowledge so it keeps going.
                send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            } else if message["method"] as? String == "textDocument/publishDiagnostics",
                      let params = message["params"] as? [String: Any], let uri = params["uri"] as? String,
                      let url = URL(string: uri) {
                diagnostics[url.path] = Self.diagnostics(from: params["diagnostics"])
            }
        }
    }

    static func diagnostics(from raw: Any?) -> [LSPDiagnostic] {
        (raw as? [[String: Any]] ?? []).compactMap { item in
            guard let range = item["range"] as? [String: Any], let start = range["start"] as? [String: Any],
                  let end = range["end"] as? [String: Any], let message = item["message"] as? String,
                  let line = start["line"] as? Int, let column = start["character"] as? Int,
                  let endLine = end["line"] as? Int, let endColumn = end["character"] as? Int else { return nil }
            let severity: Diagnostic.Severity
            switch item["severity"] as? Int { case 1: severity = .error; case 2: severity = .warning; default: severity = .note }
            return LSPDiagnostic(line: line, column: column, endLine: endLine, endColumn: endColumn, severity: severity, message: message)
        }
    }
}

/// A symbol in an outline or a project-wide search. Positions are 0-based as in the protocol.
public struct LSPSymbol: Identifiable, Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case other = 0, file = 1, module, namespace, package, `class`, method, property, field, constructor, `enum`, interface,
             function, variable, constant, string, number, boolean, array, object, key, null, enumMember, `struct`, event, `operator`, typeParameter
        public var label: String {
            switch self {
            case .class: "class"; case .struct: "struct"; case .enum: "enum"; case .interface: "protocol"; case .method: "method"
            case .function: "func"; case .property, .field: "property"; case .variable: "var"; case .constant: "let"
            case .constructor: "init"; case .enumMember: "case"; case .module, .namespace, .package: "module"; default: "symbol"
            }
        }
        public var symbolName: String {
            switch self {
            case .class: "c.square"; case .struct: "s.square"; case .enum: "e.square"; case .interface: "p.square"
            case .method, .function, .constructor: "f.square"; case .property, .field, .variable, .constant: "v.square"
            case .enumMember: "e.square"; case .module, .namespace, .package: "m.square"; default: "square"
            }
        }
    }
    public var id = UUID()
    public var name: String
    public var detail: String?
    public var kind: Kind
    public var path: String?
    public var line: Int
    public var column: Int
    public var endLine: Int
    public var children: [LSPSymbol]

    /// The outline flattened depth-first, each with its nesting depth, for lists and the jump bar.
    public func flattened(depth: Int = 0) -> [(symbol: LSPSymbol, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }

    /// The chain of symbols that contain a 0-based line, outermost first (what the jump bar shows).
    public static func trail(at line: Int, in symbols: [LSPSymbol]) -> [LSPSymbol] {
        guard let hit = symbols.last(where: { $0.line <= line && line <= max($0.endLine, $0.line) }) else { return [] }
        return [hit] + trail(at: line, in: hit.children)
    }
}

public struct LSPTextEdit: Equatable, Sendable {
    public var line: Int, column: Int, endLine: Int, endColumn: Int
    public var newText: String
}

public struct LSPWorkspaceEdit: Equatable, Sendable {
    public var edits: [String: [LSPTextEdit]]
    public var fileCount: Int { edits.count }
    public var editCount: Int { edits.values.reduce(0) { $0 + $1.count } }

    /// Applies edits (0-based line, UTF-16 character) to text. Edits are applied last-to-first so earlier offsets hold.
    public static func apply(_ edits: [LSPTextEdit], to text: String) -> String {
        let ns = text as NSString
        var lineStarts = [0]
        var index = 0
        while index < ns.length {
            let char = ns.character(at: index)
            if char == 10 { lineStarts.append(index + 1) }
            index += 1
        }
        func offset(_ line: Int, _ column: Int) -> Int {
            guard line < lineStarts.count else { return ns.length }
            let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] : ns.length
            return min(lineStarts[line] + column, lineEnd)
        }
        var result = ns
        let ordered = edits.sorted { ($0.line, $0.column) > ($1.line, $1.column) }
        for edit in ordered {
            let start = offset(edit.line, edit.column), end = max(start, offset(edit.endLine, edit.endColumn))
            result = result.replacingCharacters(in: NSRange(location: start, length: end - start), with: edit.newText) as NSString
        }
        return result as String
    }
}
