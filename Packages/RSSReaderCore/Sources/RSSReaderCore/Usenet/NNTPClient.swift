import Foundation
import Network

/// Minimal, actor-isolated NNTP client built on Network.framework.
@available(macOS 10.15, iOS 13.0, *)
public actor NNTPClient {
    public let configuration: UsenetServerConfig

    private let queue = DispatchQueue(label: "com.modernreader.nntp")
    private var connection: NWConnection?
    private var buffer = Data()
    private var currentGroup: String?
    private var didAuthenticate = false

    public init(configuration: UsenetServerConfig) {
        self.configuration = configuration
    }

    public var isConnected: Bool { connection != nil }

    // MARK: - Lifecycle

    public func connect(username: String? = nil, password: String? = nil) async throws {
        guard connection == nil else { return }

        // Timeouts: 25s connect / 60s read; cancel kills the connection.
        try await withTimeout(seconds: 25, activity: "connecting to \(configuration.host)") {
            try await self.connectInternal(username: username, password: password)
        }
    }

    private func connectInternal(username: String? = nil, password: String? = nil) async throws {

        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = configuration.useTLS
            ? NWParameters(tls: tlsOptions, tcp: tcpOptions)
            : NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: configuration.port)) else {
            throw NNTPError.connectionFailed("Invalid port \(configuration.port)")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        )
        self.connection = connection
        self.buffer.removeAll(keepingCapacity: true)

        try await awaitReady(connection)

        let banner = try await readLine()
        guard let status = NNTPStatus(line: banner), status.code == 200 || status.code == 201 else {
            let failure = NNTPStatus(line: banner)?.error ?? NNTPError.invalidResponse(banner)
            self.connection?.cancel()
            self.connection = nil
            throw failure
        }

        // Servers that advertise MODE READER (INN/common) should receive it before auth.
        _ = try await sendCommand("MODE READER")

        if let username, !username.isEmpty, let password {
            try await authenticate(username: username, password: password)
        }
    }

    public func disconnect() async {
        if connection != nil {
            _ = try? await sendCommand("QUIT")
        }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        currentGroup = nil
        didAuthenticate = false
    }

    // MARK: - Authentication

    public func authenticate(username: String, password: String) async throws {
        let user = try NNTPWire.validateArgument(username)
        let pass = try NNTPWire.validateArgument(password)

        let userStatus = try await sendCommand("AUTHINFO USER \(user)")
        if userStatus.code == 281 {
            didAuthenticate = true
            return
        }
        guard userStatus.code == 381 else {
            throw NNTPError.unexpectedStatus(userStatus.code, userStatus.message)
        }

        let passStatus = try await sendCommand("AUTHINFO PASS \(pass)")
        guard passStatus.code == 281 else {
            throw NNTPError.unexpectedStatus(passStatus.code, passStatus.message)
        }
        didAuthenticate = true
    }

    // MARK: - Capabilities

    public func capabilities() async throws -> [String] {
        let status = try await sendCommand("CAPABILITIES")
        guard status.code == 101 else { return [] }
        return try await readMultiline()
    }

    // MARK: - Groups

    public func listActive(prefix: String? = nil) async throws -> [NNTPGroupInfo] {
        let command: String
        if let prefix, !prefix.isEmpty {
            let safe = try NNTPWire.validateArgument(prefix)
            command = "LIST ACTIVE \(safe)*"
        } else {
            command = "LIST ACTIVE"
        }
        let status = try await sendCommand(command)
        guard status.code == 215 else {
            throw NNTPError.unexpectedStatus(status.code, status.message)
        }
        let lines = try await readMultiline()
        return lines.compactMap(NNTPWire.parseGroupListLine)
    }

    @discardableResult
    public func selectGroup(_ name: String) async throws -> NNTPGroupInfo {
        let safe = try NNTPWire.validateArgument(name)
        let status = try await sendCommand("GROUP \(safe)")
        guard status.code == 211 else {
            throw NNTPError.unexpectedStatus(status.code, status.message)
        }
        let parts = status.message.split(separator: " ")
        guard parts.count >= 4,
              let count = Int(parts[0]),
              let low = Int(parts[1]),
              let high = Int(parts[2]) else {
            throw NNTPError.protocolViolation("Malformed GROUP response: \(status.message)")
        }
        currentGroup = safe
        return NNTPGroupInfo(name: String(parts[3]), articleCount: count, lowWater: low, highWater: high)
    }

    public func overview(group: String, range: ClosedRange<Int>) async throws -> [NNTPOverviewEntry] {
        _ = try await selectGroup(group)
        let status = try await sendCommand("OVER \(range.lowerBound)-\(range.upperBound)")
        guard status.code == 224 else {
            throw NNTPError.unexpectedStatus(status.code, status.message)
        }
        let lines = try await readMultiline()
        return lines.compactMap(NNTPWire.parseOverviewLine)
    }

    public func latestOverviews(group: String, limit: Int = 100) async throws -> [NNTPOverviewEntry] {
        let info = try await selectGroup(group)
        guard info.highWater > 0 else { return [] }
        let count = max(1, min(limit, 5_000))
        let low = max(info.lowWater, info.highWater - count + 1)
        let status = try await sendCommand("OVER \(low)-\(info.highWater)")
        guard status.code == 224 else {
            throw NNTPError.unexpectedStatus(status.code, status.message)
        }
        let lines = try await readMultiline()
        return lines.compactMap(NNTPWire.parseOverviewLine)
    }

    // MARK: - Articles

    public func article(group: String, number: Int) async throws -> UsenetArticle {
        _ = try await selectGroup(group)
        let status = try await sendCommand("ARTICLE \(number)")
        guard status.code == 220 else {
            throw NNTPError.unexpectedStatus(status.code, status.message)
        }
        let lines = try await readMultiline()
        let (headers, body) = NNTPWire.parseArticle(lines)
        return makeArticle(headers: headers, body: body, group: group, number: number)
    }

    public func article(messageID: String) async throws -> UsenetArticle {
        let safe = try NNTPWire.validateArgument(messageID)
        let identifier = safe.hasPrefix("<") ? safe : "<\(safe)>"
        let status = try await sendCommand("ARTICLE \(identifier)")
        guard status.code == 220 else {
            throw NNTPError.unexpectedStatus(status.code, status.message)
        }
        let lines = try await readMultiline()
        let (headers, body) = NNTPWire.parseArticle(lines)
        let group = headers["newsgroups"]?.split(separator: ",").first.map(String.init) ?? currentGroup ?? ""
        let number = Int(status.message.split(separator: " ").first.map(String.init) ?? "") ?? 0
        return makeArticle(headers: headers, body: body, group: group, number: number)
    }

    // MARK: - Transport

    private func makeArticle(
        headers: [String: String],
        body: String,
        group: String,
        number: Int
    ) -> UsenetArticle {
        let messageID = (headers["message-id"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let subject = headers["subject"] ?? "(no subject)"
        let author = NNTPWire.displayAuthor(from: headers["from"] ?? "Unknown")
        let date = FeedDateParser.parse(headers["date"]) ?? .now
        let references = NNTPWire.references(from: headers["references"] ?? "")
        return UsenetArticle(
            serverID: configuration.id,
            groupName: group,
            number: number,
            messageID: messageID,
            subject: subject,
            author: author,
            date: date,
            references: references,
            body: body,
            headers: headers
        )
    }

    private func sendCommand(_ command: String) async throws -> NNTPStatus {
        try NNTPWire.validateCommand(command)
        try await sendRaw(command + "\r\n")
        let line = try await readLine()
        guard let status = NNTPStatus(line: line) else {
            throw NNTPError.invalidResponse(line)
        }
        return status
    }

    private func sendRaw(_ string: String) async throws {
        guard let connection else { throw NNTPError.notConnected }
        let data = Data(string.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: NNTPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex...newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.last == 0x0A { line = line.dropLast() }
                if line.last == 0x0D { line = line.dropLast() }
                return String(decoding: line, as: UTF8.self)
            }
            try await receiveMore()
        }
    }

    private func readMultiline() async throws -> [String] {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            if line == "." { break }
            lines.append(line)
            if lines.count > 500_000 {
                throw NNTPError.protocolViolation("Multiline response exceeded safety limit.")
            }
        }
        return NNTPWire.decodeDotStuffed(lines)
    }

    // Timeout wrapper (connect 25s; read 60s via cancel).
    private func withTimeout<T: Sendable>(seconds: TimeInterval, activity: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw NNTPError.timedOut(activity)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func receiveMore() async throws {
        guard let connection else { throw NNTPError.notConnected }
        let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: NNTPError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: NNTPError.connectionClosed)
                } else {
                    continuation.resume(throwing: NNTPError.connectionClosed)
                }
            }
        }
        buffer.append(chunk)
    }

    private func awaitReady(_ connection: NWConnection) async throws {
        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resumeOnce { continuation.resume() }
                case .failed(let error):
                    box.resumeOnce {
                        continuation.resume(
                            throwing: NNTPError.connectionFailed(error.localizedDescription)
                        )
                    }
                case .cancelled:
                    box.resumeOnce { continuation.resume(throwing: NNTPError.connectionClosed) }
                case .waiting:
                    // Don't treat a transient waiting state as fatal.
                    // Only fail after the outer 25s timeout kills this.
                    break
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

/// Guards a continuation so it can only be resumed once across state callbacks.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        body()
    }
}
