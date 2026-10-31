import Foundation

/// App-wide count of audit entries that could not be written.
///
/// Each agent run has its own recorder; if the chain refuses an append the run carries on (failing
/// closed would change what an agent may do whenever the disk misbehaves). The loss must still be
/// visible, so recorders report it here and the audit panel shows it. A non-zero count means the
/// trail has a hole, whatever `verify()` says about the entries that did get written.
public final class AuditHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var dropped = 0
    private var last: String?

    public init() {}

    func note(_ error: Error) {
        lock.withLock {
            dropped += 1
            last = error.localizedDescription
        }
    }

    public var snapshot: (dropped: Int, lastFailure: String?) { lock.withLock { (dropped, last) } }
}
