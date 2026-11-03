import Foundation
import KilnRemoteKit

/// Keeps one outbound connection to a Kiln relay so devices away from home can reach this Mac with no port forwarding.
/// The relay forwards sealed frames it cannot read; each device gets its own `RemoteConnection` over a slice of the socket.
@MainActor
final class RemoteRelayClient {
    private let relay: URL
    private let pairingKey: Data
    private let bridge: RemoteBridge
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var devices: [UInt32: RemoteConnection] = [:]
    /// Every frame to the relay goes through one ordered queue: sealed frames carry a counter, so reordering would drop the device.
    private var outbound: AsyncStream<Data>.Continuation?
    private let session = URLSession(configuration: .ephemeral)
    private(set) var isConnected = false
    var onChange: () -> Void = {}
    var onDevice: (RemoteConnection) -> Void = { _ in }
    var lastError: String?

    init(relay: URL, pairingKey: Data, bridge: RemoteBridge) {
        self.relay = relay
        self.pairingKey = pairingKey
        self.bridge = bridge
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var delay: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                let ranFor = await self.runOnce()
                if ranFor > 20 { delay = 1 }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        for connection in devices.values { connection.transportClosed() }
        devices = [:]
        isConnected = false
        onChange()
    }

    /// One connection lifetime; returns how long it stayed up.
    private func runOnce() async -> Double {
        guard let url = RelayAddress.url(relay: relay, pairingKey: pairingKey, role: .mac) else { return 0 }
        var request = URLRequest(url: url)
        request.setValue(RelayAddress.authorizationHeader(pairingKey: pairingKey), forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        let started = Date()
        do {
            // The first successful receive-or-ping proves the relay accepted us.
            try await ping(task)
            let (frames, continuation) = AsyncStream.makeStream(of: Data.self)
            outbound = continuation
            let writer = Task { for await frame in frames { try? await task.send(.data(frame)) } }
            defer { continuation.finish(); writer.cancel(); outbound = nil }
            isConnected = true; lastError = nil; onChange()
            // A link that dies without a close (sleep, Wi-Fi change, a middlebox dropping idle sockets) would otherwise
            // look connected forever and the relay would think this Mac is offline. Ping, and drop the socket when no answer.
            let keepalive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, let self else { return }
                    do { try await self.pingWithTimeout(task, seconds: 10) } catch {
                        self.lastError = "Relay: no answer, reconnecting"
                        task.cancel(with: .abnormalClosure, reason: nil)
                        return
                    }
                }
            }
            defer { keepalive.cancel() }
            while !Task.isCancelled {
                let message = try await task.receive()
                if case .data(let data) = message { handle(data) }
            }
        } catch {
            lastError = "Relay: \(error.localizedDescription)"
        }
        isConnected = false
        for connection in devices.values { connection.transportClosed() }
        devices = [:]
        onChange()
        return Date().timeIntervalSince(started)
    }

    private func pingWithTimeout(_ task: URLSessionWebSocketTask, seconds: Double) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.ping(task) }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The pong handler can be called more than once when the socket is cancelled; resume only the first time.
            let once = PingOnce(continuation)
            task.sendPing { error in once.resume(error) }
        }
    }

    private func handle(_ frame: Data) {
        guard let (kind, id, payload) = RelayFrame.decode(frame) else { return }
        switch kind {
        case .deviceJoined:
            let queue = outbound
            let transport = RelayDeviceTransport(id: id, send: { data in
                queue?.yield(RelayFrame.encode(.data, device: id, payload: data))
            }, close: {
                queue?.yield(RelayFrame.encode(.closeDevice, device: id))
            })
            let connection = RemoteConnection(transport: transport, pairingKey: pairingKey, bridge: bridge)
            devices[id] = connection
            connection.onClose = { [weak self] in Task { @MainActor in self?.devices[id] = nil; self?.onChange() } }
            onDevice(connection)   // the server registers it and starts it
        case .deviceLeft:
            devices.removeValue(forKey: id)?.transportClosed()
        case .data:
            devices[id]?.receive(payload)
        case .closeDevice:
            break
        }
    }
}

final class RelayDeviceTransport: FrameTransport, @unchecked Sendable {
    let id: UInt32
    private let sendFrame: @Sendable (Data) -> Void
    private let closeDevice: @Sendable () -> Void
    init(id: UInt32, send: @escaping @Sendable (Data) -> Void, close: @escaping @Sendable () -> Void) {
        self.id = id; sendFrame = send; closeDevice = close
    }
    func send(_ data: Data) { sendFrame(data) }
    func close() { closeDevice() }
}

/// Resumes a ping's continuation exactly once, however many times URLSession calls the handler.
private final class PingOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func resume(_ error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        guard let c else { return }
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
