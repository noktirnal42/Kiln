import Foundation
import Network

public enum MailTransportError: Error, Equatable, LocalizedError {
    case connectFailed(String), closed, timedOut, protocolError(String), authenticationFailed(String), serverRejected(String)
    public var errorDescription: String? {
        switch self {
        case .connectFailed(let m): "Could not connect: \(m)"
        case .closed: "The mail server closed the connection."
        case .timedOut: "The mail server did not answer in time."
        case .protocolError(let m): "Unexpected reply from the mail server: \(m)"
        case .authenticationFailed(let m): "The mail server refused the sign-in: \(m)"
        case .serverRejected(let m): "The mail server refused the request: \(m)"
        }
    }
}

public enum MailSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAP 993, SMTP 465). The normal choice.
    case tls
    /// No encryption. Only accepted for loopback hosts (tests and local servers); a real server needs TLS.
    case none

    public var label: String { self == .tls ? "TLS (encrypted)" : "None (localhost only)" }
}

/// A buffered, line-oriented connection for IMAP and SMTP. One reader at a time.
public actor MailConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var started = false
    public let timeout: TimeInterval

    public init(host: String, port: Int, security: MailSecurity, timeout: TimeInterval = 20) throws {
        if security == .none, !Self.isLoopback(host) { throw MailTransportError.connectFailed("Unencrypted mail is only allowed for this Mac (localhost). Use TLS.") }
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw MailTransportError.connectFailed("Invalid port \(port).") }
        let parameters: NWParameters = security == .tls ? .tls : .tcp
        connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters)
        self.timeout = timeout
    }

    static func isLoopback(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) }

    public func connect() async throws {
        guard !started else { return }
        started = true
        try await withTimeout { [connection] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                connection.stateUpdateHandler = { state in
                    guard !once.done else { return }
                    switch state {
                    case .ready: once.done = true; continuation.resume()
                    case .failed(let e): once.done = true; continuation.resume(throwing: MailTransportError.connectFailed(e.localizedDescription))
                    case .waiting(let e): once.done = true; connection.cancel(); continuation.resume(throwing: MailTransportError.connectFailed(e.localizedDescription))
                    case .cancelled: once.done = true; continuation.resume(throwing: MailTransportError.closed)
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    public func send(_ text: String) async throws { try await send(Data(text.utf8)) }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: MailTransportError.connectFailed(error.localizedDescription)) } else { continuation.resume() }
            })
        }
    }

    /// One line without its CRLF.
    public func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer[buffer.startIndex..<range.lowerBound]
                buffer = Data(buffer[range.upperBound...])
                return String(decoding: line, as: UTF8.self)
            }
            try await fill()
        }
    }

    public func read(count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let out = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return out
    }

    public func close() { connection.cancel() }

    private func fill() async throws {
        let chunk: Data = try await withTimeout { [connection] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: MailTransportError.connectFailed(error.localizedDescription)) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: isComplete ? MailTransportError.closed : MailTransportError.protocolError("empty read")) }
                }
            }
        }
        buffer.append(chunk)
    }

    private func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let seconds = timeout
        let connection = self.connection
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                connection.cancel()
                throw MailTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MailTransportError.closed }
            return first
        }
    }
}
