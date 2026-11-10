import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 for tests: serves routes, honours `Range`, and can cut a response short.
final class LoopbackServer: @unchecked Sendable {
    struct Request { let method: String; let path: String; let headers: [String: String]; var rangeStart: Int? }
    struct Response {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        /// Send only this many body bytes, then close, to simulate a dropped connection.
        var cutAfter: Int?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback")
    private let lock = NSLock()
    private var _requests: [Request] = []
    var handler: @Sendable (Request) -> Response = { _ in Response(status: 404) }
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: if !done { done = true; port = listener.port?.rawValue ?? 0; c.resume() }
                case .failed(let error): if !done { done = true; c.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            guard let data, let head = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            guard parts.count >= 2 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() { if let i = line.firstIndex(of: ":") { headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            var request = Request(method: String(parts[0]), path: String(parts[1]), headers: headers)
            if let range = headers["range"], range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") { request.rangeStart = start }
            lock.lock(); _requests.append(request); lock.unlock()
            var response = handler(request)
            var status = response.status
            var body = response.body
            if let start = request.rangeStart, status == 200 {
                status = 206
                response.headers["Content-Range"] = "bytes \(start)-\(max(start, body.count - 1))/\(body.count)"
                body = start < body.count ? body.subdata(in: start..<body.count) : Data()
            }
            let reason = status == 206 ? "Partial Content" : (status == 200 ? "OK" : "Error")
            var out = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            for (k, v) in response.headers { out += "\(k): \(v)\r\n" }
            out += "\r\n"
            var payload = Data(out.utf8)
            if request.method == "HEAD" { /* no body */ } else { payload.append(response.cutAfter.map { body.prefix($0) } ?? body) }
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
