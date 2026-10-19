import Foundation

// Emulation session scaffolding (docs/KALI_METASPLOIT_PARITY.md T8, v1): the consent, audit,
// and host contract that every emulation run goes through, whatever the engine underneath.
// v1's host is the KDF replay path (derive what the device derives, on-device, without
// executing target code). The Ghidra p-code host — function-level and loader-level emulation
// with tracing and watchpoints — lands behind this same contract once roadmap B wires the
// persistent engine worker (docs/ENGINE_WORKER.md); nothing here changes when it does.
// Emulated code never executes natively on the host; every session is consent-gated and
// audit-logged, carrying the reliability/side-effect discipline adopted from the Metasploit
// determination.

public struct EmulationConsent {
    /// The analyst's explicit statement that this run may emulate code extracted from the
    /// analyzed image. Axiom never implies it; the caller (UI/CLI) collects it.
    public let granted: Bool
    public let scope: String        // e.g. "single function", "loader stage", "kdf replay"
    public init(granted: Bool, scope: String) {
        self.granted = granted; self.scope = scope
    }
}

/// One emulation operation a host can perform. v1 implements replay; p-code adds the rest.
public enum EmulationOperation: Sendable {
    case kdfReplay(KDFReplayParameters)
    case pCodeFunction(bytes: Data, base: UInt64, watchpoints: [UInt64])   // roadmap B: p-code host
}

/// The host contract. Implementations must be deterministic for identical inputs (recorded
/// model/parameter versions in the audit entry make runs reproducible and reviewable).
public protocol EmulationHost: Sendable {
    func supports(_ operation: EmulationOperation) -> Bool
    func run(_ operation: EmulationOperation, consent: EmulationConsent) throws -> EmulationResult
}

public struct EmulationResult: Codable, Sendable {
    public let operation: String
    public let outputHex: String
    public let audit: DeviceSessionRecord
}

/// The default host: KDF replay. Refuses any operation it does not implement — silently
/// pretending to emulate something would violate the no-fabricated-success rule.
public struct KDFReplayHost: EmulationHost {
    public init() {}

    public func supports(_ operation: EmulationOperation) -> Bool {
        if case .kdfReplay = operation { return true }
        return false
    }

    public func run(_ operation: EmulationOperation, consent: EmulationConsent) throws -> EmulationResult {
        guard consent.granted else {
            throw AxiomError.message("Emulation requires explicit consent (scope: \(consent.scope)).")
        }
        switch operation {
        case .kdfReplay(let parameters):
            let key = try KDFReplay.derive(parameters)
            let audit = DeviceSessionRecord(kind: "emulation", target: "kdf-replay",
                                            sideEffects: "none — pure derivation on extracted parameters",
                                            notes: ["algorithm: \(parameters.algorithm)", "iterations: \(parameters.iterations)",
                                                    "consent scope: \(consent.scope)"])
            return EmulationResult(operation: "\(parameters.algorithm) (\(parameters.iterations) rounds)",
                                   outputHex: Hex.encode(key), audit: audit)
        case .pCodeFunction:
            throw AxiomError.message("p-code emulation lands with the roadmap-B engine worker (docs/ENGINE_WORKER.md); the v1 host refuses it rather than faking it.")
        }
    }
}
