import Foundation
import Testing
@testable import Kiln

/// Answers Ollama's HTTP API in process; one host name per test.
final class OllamaStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body = "" }
    nonisolated(unsafe) static var handlers: [String: @Sendable (String, String, String) -> Reply] = [:]   // host -> (method, path, body) -> reply
    nonisolated(unsafe) static var requests: [String: [String]] = [:]
    static let lock = NSLock()
    static func install(host: String, _ handler: @escaping @Sendable (String, String, String) -> Reply) { lock.lock(); handlers[host] = handler; requests[host] = []; lock.unlock() }
    static func seen(_ host: String) -> [String] { lock.lock(); defer { lock.unlock() }; return requests[host] ?? [] }
    static func library(_ host: String, free: Int64 = Int64.max) -> OllamaLibrary {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OllamaStub.self]
        return OllamaLibrary(baseURL: URL(string: "http://\(host)")!, session: URLSession(configuration: config), freeSpace: { free })
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!, host = url.host ?? ""
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? (request.httpBodyStream.map { stream -> String in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return String(data: data, encoding: .utf8) ?? ""
        } ?? "")
        Self.lock.lock(); Self.requests[host, default: []].append("\(request.httpMethod ?? "GET") \(url.path) \(body)"); let handler = Self.handlers[host]; Self.lock.unlock()
        let reply = handler?(request.httpMethod ?? "GET", url.path, body) ?? Reply(status: 404, body: "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}

struct OllamaLibraryTests {
    @Test func namesAreValidatedBeforeAnythingIsSent() throws {
        #expect(try OllamaLibrary.validate("llama3.2:3b") == "llama3.2:3b")
        #expect(try OllamaLibrary.validate("hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M") == "hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M")
        for bad in ["", "   ", "-rf", "/etc/passwd", "a b", "x;rm -rf", "a..b", "$(whoami)", String(repeating: "a", count: 201)] {
            #expect(throws: OllamaLibraryError.self) { try OllamaLibrary.validate(bad) }
        }
    }

    @Test func installedModelsAreParsedSortedWithDetails() async throws {
        OllamaStub.install(host: "ollama-list.test") { _, path, _ in
            path == "/api/tags" ? .init(body: #"{"models":[{"name":"zeta:1b","size":1000,"modified_at":"2026-11-12T16:30:03-07:00","details":{"parameter_size":"1B","quantization_level":"Q4_0","family":"llama"}},{"name":"alpha:8b","size":5000000000}]}"#) : .init(status: 404)
        }
        let models = try await OllamaStub.library("ollama-list.test").installed()
        #expect(models.map(\.name) == ["alpha:8b", "zeta:1b"])
        #expect(models[1].quantization == "Q4_0" && models[1].parameterSize == "1B" && models[1].modified != nil)
        #expect(models[0].sizeBytes == 5_000_000_000)
    }

    @Test func aServerThatIsNotRunningIsReportedPlainly() async {
        let config = URLSessionConfiguration.ephemeral
        let library = OllamaLibrary(baseURL: URL(string: "http://127.0.0.1:1")!, session: URLSession(configuration: config))
        await #expect(throws: OllamaLibraryError.notRunning("http://127.0.0.1:1")) { try await library.installed() }
    }

    @Test func aPullYieldsProgressAndFinishes() async throws {
        OllamaStub.install(host: "ollama-pull.test") { method, path, body in
            guard method == "POST", path == "/api/pull", body.contains("llama3.2:1b") else { return .init(status: 400) }
            return .init(body: """
            {"status":"pulling manifest"}
            {"status":"pulling abc","digest":"sha256:abc","total":1000,"completed":250}
            {"status":"pulling abc","digest":"sha256:abc","total":1000,"completed":1000}
            {"status":"success"}
            """)
        }
        var events: [OllamaPullProgress] = []
        for try await event in OllamaStub.library("ollama-pull.test").pull("llama3.2:1b") { events.append(event) }
        #expect(events.count == 4)
        #expect(events[1].fraction == 0.25 && events[2].fraction == 1.0)
        #expect(events.last?.status == "success")
    }

    @Test func aPullThatWouldNotFitIsRefusedAfterTheFirstSizedEvent() async {
        OllamaStub.install(host: "ollama-full.test") { _, _, _ in .init(body: """
            {"status":"pulling manifest"}
            {"status":"pulling big","digest":"sha256:big","total":10000000000,"completed":0}
            {"status":"pulling big","digest":"sha256:big","total":10000000000,"completed":5000000000}
            """) }
        var count = 0
        do { for try await _ in OllamaStub.library("ollama-full.test", free: 3_000_000_000).pull("huge:70b") { count += 1 }; Issue.record("expected a refusal") }
        catch let error as OllamaLibraryError { if case .notEnoughSpace(let needed, let free) = error { #expect(needed == 10_000_000_000 && free == 3_000_000_000) } else { Issue.record("wrong error \(error)") } }
        catch { Issue.record("wrong error \(error)") }
        #expect(count == 1)   // only the manifest event got through
    }

    @Test func aServerErrorInTheStreamIsSurfaced() async {
        OllamaStub.install(host: "ollama-err.test") { _, _, _ in .init(body: #"{"error":"pull model manifest: file does not exist"}"#) }
        do { for try await _ in OllamaStub.library("ollama-err.test").pull("nope:1b") {}; Issue.record("expected an error") }
        catch { #expect(error.localizedDescription.contains("file does not exist")) }
    }

    @Test func removeOnlyDeletesAnExactInstalledName() async throws {
        OllamaStub.install(host: "ollama-del.test") { method, path, body in
            if path == "/api/tags" { return .init(body: #"{"models":[{"name":"keep:1b","size":1},{"name":"gone:1b","size":2}]}"#) }
            if method == "DELETE", path == "/api/delete", body.contains("gone:1b") { return .init(status: 200) }
            return .init(status: 500)
        }
        let library = OllamaStub.library("ollama-del.test")
        try await library.delete("gone:1b")
        #expect(OllamaStub.seen("ollama-del.test").contains { $0.hasPrefix("DELETE /api/delete") && $0.contains("gone:1b") && !$0.contains("keep") })
        await #expect(throws: OllamaLibraryError.notInstalled("gone")) { try await library.delete("gone") }
        await #expect(throws: OllamaLibraryError.self) { try await library.delete("../x") }
    }
}

struct ModelLibraryToolTests {
    @Test func tiersMatchWhatEachToolDoes() {
        let specs = Dictionary(uniqueKeysWithValues: ModelLibraryTool.Kind.allCases.map { ($0.rawValue, ModelLibraryTool(kind: $0).spec) })
        #expect(specs["models_installed"]?.permission == .read && specs["models_progress"]?.permission == .read)
        #expect(specs["models_pull"]?.permission == .write && specs["models_cancel"]?.permission == .write)
        #expect(specs["models_remove"]?.permission == .admin && specs["models_remove"]?.isDestructive == true)
        #expect(specs.count == 5)
    }

    @MainActor @Test func aBadNameIsRefusedBeforeAnyRequest() async {
        let tool = ModelLibraryTool(kind: .pull)
        let context = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())
        await #expect(throws: OllamaLibraryError.self) { try await tool.execute(argumentsJSON: #"{"model":"a; rm -rf /"}"#, context: context) }
    }

    @MainActor @Test func theSharedStateTracksAPullAndRecordsItsOutcome() async throws {
        OllamaStub.install(host: "ollama-state.test") { _, path, _ in
            path == "/api/pull" ? .init(body: "{\"status\":\"pulling x\",\"total\":100,\"completed\":50}\n{\"status\":\"success\"}") : .init(body: #"{"models":[{"name":"tiny:1b","size":100}]}"#)
        }
        let state = ModelLibraryState()
        state.library = OllamaStub.library("ollama-state.test")
        let name = try state.startPull("tiny:1b")
        for _ in 0..<200 where state.pulls.first?.phase == .running { try await Task.sleep(for: .milliseconds(25)) }
        #expect(name == "tiny:1b" && state.pulls.first?.phase == .finished)
        #expect(state.installed.map(\.name) == ["tiny:1b"])
    }
}
