import Foundation
import KilnRemoteKit
import WatchConnectivity

/// What the session talks to: a direct encrypted connection (`RemoteClient`) or the iPhone bridge (`PhoneBridge`).
protocol RemoteChannel: Sendable {
    /// How it got there, for the status line ("via iPhone", "on Wi-Fi").
    var route: String { get }
    func connect() async -> AsyncThrowingStream<RemoteEvent, Error>
    func send(_ command: RemoteCommand) async throws
    func close() async
}

/// The part of WatchConnectivity the bridge needs, so tests can stand in for the phone. Values are strings because
/// messages must be property lists and this keeps them `Sendable`.
protocol BridgeMessenger: Sendable {
    var isReachable: Bool { get }
    func send(_ message: [String: String], reply: (@Sendable ([String: String]) -> Void)?, failure: @escaping @Sendable (Error) -> Void)
    func queue(_ userInfo: [String: String])
}

struct WCMessenger: BridgeMessenger {
    var isReachable: Bool { WCSession.default.activationState == .activated && WCSession.default.isReachable }

    func send(_ message: [String: String], reply: (@Sendable ([String: String]) -> Void)?, failure: @escaping @Sendable (Error) -> Void) {
        WCSession.default.sendMessage(message, replyHandler: reply.map { handler in { dictionary in handler(dictionary.compactMapValues { $0 as? String }) } }, errorHandler: failure)
    }

    func queue(_ userInfo: [String: String]) { WCSession.default.transferUserInfo(userInfo) }
}

/// Wire contract with the iPhone app (WatchConnectivity is already authenticated between paired devices, so no extra
/// encryption). Keys:
/// - watch → phone `["kilnBridge": "open"]` (message, reply expected): phone answers `["kilnBridge": "ready", "host": <Mac name>]`
///   once its own Mac connection is up, or `["kilnBridge": "error", "reason": <text>]`.
/// - watch → phone `["kilnBridgeCommand": <RemoteCommand JSON>]` (message when reachable, else transferUserInfo).
/// - watch → phone `["kilnBridge": "close"]`.
/// - phone → watch `["kilnBridgeEvent": <RemoteEvent JSON>]` for every event from the Mac (message when reachable, else userInfo).
final class PhoneBridge: RemoteChannel, @unchecked Sendable {
    static let eventKey = "kilnBridgeEvent"
    static let commandKey = "kilnBridgeCommand"
    static let controlKey = "kilnBridge"

    let route = "via iPhone"
    private let messenger: BridgeMessenger
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<RemoteEvent, Error>.Continuation?
    private var host = "Mac"

    init(messenger: BridgeMessenger) { self.messenger = messenger }

    var isReachable: Bool { messenger.isReachable }

    /// Asks the phone to bridge. Returns the Mac's name once the phone's own connection is up.
    func open(timeout: Double = 8) async throws -> String {
        let once = Once<String>()
        let messenger = messenger
        let name = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                once.install(continuation)
                messenger.send([Self.controlKey: "open"], reply: { reply in
                    if reply[Self.controlKey] == "ready" { once.finish(.success(reply["host"] ?? "Mac")) } else {
                        once.finish(.failure(RemoteError.bridge(reply["reason"] ?? "Mac not connected on the iPhone")))
                    }
                }, failure: { once.finish(.failure($0)) })
                Task { try? await Task.sleep(for: .seconds(timeout)); once.finish(.failure(RemoteError.timeout)) }
            }
        } onCancel: { once.finish(.failure(CancellationError())) }
        lock.withLock { host = name }
        return name
    }

    func connect() async -> AsyncThrowingStream<RemoteEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RemoteEvent.self)
        let name = lock.withLock { () -> String in self.continuation = continuation; return host }
        continuation.yield(.welcome(hostName: name, protocolVersion: kilnRemoteProtocolVersion))
        return stream
    }

    func send(_ command: RemoteCommand) async throws {
        let json = String(decoding: try RemoteCoding.encode(command), as: UTF8.self)
        let message = [Self.commandKey: json]
        guard messenger.isReachable else { throw RemoteError.bridge("iPhone not reachable") }
        messenger.send(message, reply: nil, failure: { _ in })
    }

    func close() async {
        messenger.send([Self.controlKey: "close"], reply: nil, failure: { _ in })
        let old = lock.withLock { () -> AsyncThrowingStream<RemoteEvent, Error>.Continuation? in defer { continuation = nil }; return continuation }
        old?.finish()
    }

    /// Called by `PhoneLink` for every `kilnBridgeEvent` from the phone.
    func deliver(_ json: String) {
        guard let event = try? RemoteCoding.decode(RemoteEvent.self, from: Data(json.utf8)) else { return }
        _ = lock.withLock { continuation }?.yield(event)
    }
}

/// Resumes a continuation exactly once, whichever of reply, failure, timeout or cancellation comes first.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let pending = lock.withLock { () -> Result<T, Error>? in
            if let early { done = true; return early }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func finish(_ result: Result<T, Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<T, Error>? in
            guard !done else { return nil }
            if let continuation { done = true; self.continuation = nil; return continuation }
            if early == nil { early = result }
            return nil
        }
        cont?.resume(with: result)
    }
}
