import Foundation
import KilnRemoteKit
import Network

enum RemoteError: Error, Equatable {
    case timeout, closed, badHandshake, notReady, notFound
    /// Every way of reaching the Mac failed; one line per attempt ("192.168.1.20:47900: timed out").
    case attemptsFailed([String])
    /// The iPhone could not bridge (its Mac connection is down, or it is not paired).
    case bridge(String)
}

/// Carries opaque binary frames to the Mac. `send` is synchronous and ordered so the encrypted frame counter
/// can never be reordered on the wire; failures end `incoming`.
protocol RemoteTransport: Sendable {
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data)
    func close()
}

func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw RemoteError.timeout }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw RemoteError.closed }
        return first
    }
}

/// WebSocket client over Network.framework. The WebSocket protocol only runs when the connection is made to a
/// URL endpoint (see docs/14-REMOTE-CONTROL.md).
final class NWTransport: RemoteTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "kiln.watch.transport")
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let states: AsyncStream<NWConnection.State>
    private let stateContinuation: AsyncStream<NWConnection.State>.Continuation

    init(url: URL, headers: [String: String] = [:]) {
        let websocket = NWProtocolWebSocket.Options()
        if !headers.isEmpty { websocket.setAdditionalHeaders(headers.map { ($0.key, $0.value) }) }
        let parameters: NWParameters = url.scheme == "wss" ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        (states, stateContinuation) = AsyncStream.makeStream(of: NWConnection.State.self)
    }

    /// Resolves once the socket is ready; throws if it fails or does not become ready in `timeout` seconds.
    func start(timeout: Double = 8) async throws {
        let continuation = continuation, stateContinuation = stateContinuation
        connection.stateUpdateHandler = { state in
            stateContinuation.yield(state)
            switch state {
            case .failed(let error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        let states = states
        try await withTimeout(timeout) {
            for await state in states {
                switch state {
                case .ready: return
                case .failed(let error): throw error
                case .cancelled: throw RemoteError.closed
                default: continue
                }
            }
            throw RemoteError.closed
        }
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.continuation.finish(throwing: error); return }
            guard let data else { self.continuation.finish(); return }
            self.continuation.yield(data)
            self.receive()
        }
    }

    func send(_ data: Data) {
        let context = NWConnection.ContentContext(identifier: "kiln-frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [continuation] error in
            if let error { continuation.finish(throwing: error) }
        })
    }

    func close() {
        connection.cancel()
        continuation.finish()
    }
}

/// Finds the Mac's `_kiln-remote._tcp` service by name and resolves it to a `ws://host:port` URL.
enum BonjourResolver {
    static func resolve(serviceName: String, timeout: Double = 10) async throws -> URL {
        let endpoint = try await browse(serviceName: serviceName, timeout: timeout)
        return try await withTimeout(timeout) { try await address(of: endpoint) }
    }

    private static func browse(serviceName: String, timeout: Double) async throws -> NWEndpoint {
        let browser = NWBrowser(for: .bonjour(type: kilnRemoteServiceType, domain: nil), using: .tcp)
        let (results, continuation) = AsyncStream.makeStream(of: NWEndpoint.self)
        browser.browseResultsChangedHandler = { found, _ in
            for result in found {
                if case .service(let name, _, _, _) = result.endpoint, name == serviceName { continuation.yield(result.endpoint) }
            }
        }
        browser.stateUpdateHandler = { if case .failed = $0 { continuation.finish() } }
        browser.start(queue: .global())
        defer { browser.cancel(); continuation.finish() }
        return try await withTimeout(timeout) {
            for await endpoint in results { return endpoint }
            throw RemoteError.notFound
        }
    }

    /// A Bonjour endpoint cannot carry the WebSocket protocol, so a plain TCP connection resolves it to host and port.
    private static func address(of endpoint: NWEndpoint) async throws -> URL {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let (states, continuation) = AsyncStream.makeStream(of: NWConnection.State.self)
        connection.stateUpdateHandler = { continuation.yield($0) }
        connection.start(queue: .global())
        defer { connection.cancel(); continuation.finish() }
        for await state in states {
            switch state {
            case .ready:
                guard case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { throw RemoteError.notFound }
                let text = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                guard let url = URL(string: "ws://\(text):\(port.rawValue)") else { throw RemoteError.notFound }
                return url
            case .failed(let error): throw error
            case .cancelled: throw RemoteError.closed
            default: continue
            }
        }
        throw RemoteError.closed
    }
}
