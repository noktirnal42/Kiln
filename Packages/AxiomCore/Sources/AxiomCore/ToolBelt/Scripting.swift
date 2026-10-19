import Foundation
import JavaScriptCore

// Scripting console (docs/KALI_METASPLOIT_PARITY.md T9): an embedded JavaScript lab console
// (JavaScriptCore — ships in the OS, zero new dependencies) with an API surface mirroring the
// MCP tools, so an analyst can automate analysis — sweep patterns, triage blobs, run decrypt
// passes, replay KDFs — in one scripted flow. v1 exposes read-only analysis and local
// computation only: target-facing I/O (serial, probes, emulated targets) stays out of the
// console until its consent plumbing is UI-driven, per the parity doc's session discipline.
// ScriptConsole is an in-process evaluator for trusted, bounded scripts. The CLI runs it
// in a disposable worker supervised by ProcessRunner; a timeout kills runaway JavaScript.
// This is process isolation, not a filesystem or memory sandbox.

/// The `axiom` object injected into every script: analysis operations over bounded inputs.
@objc protocol AxiomScriptBridgeExports: JSExport {
    func triage(_ path: String) -> NSDictionary
    func carve(_ path: String) -> NSArray
    func entropyRegions(_ path: String) -> NSArray
    func scanCrypto(_ path: String) -> NSArray
    func decrypt(_ path: String, _ options: NSDictionary) -> NSArray
    func kdf(_ algorithm: String, _ password: String, _ saltHex: String, _ iterations: Int, _ keyLength: Int) -> NSString
    func cyclicPattern(_ length: Int) -> NSString
    func patternOffset(_ query: String) -> Int
    func crc32(_ hex: String) -> UInt32
    func log(_ message: String)
}

public final class AxiomScriptBridge: NSObject, AxiomScriptBridgeExports {
    public private(set) var consoleOutput: [String] = []
    public private(set) var droppedLogLines = 0

    func resetOutput() { consoleOutput.removeAll(keepingCapacity: true); droppedLogLines = 0 }

    func triage(_ path: String) -> NSDictionary {
        let data = try? ToolBelt.readData(path)
        guard let data else { return ["error": "cannot read \(path)"] }
        return ["size": data.count,
                "crypto": CryptoIdentifier.scan(data).map(hitDictionary),
                "formats": FormatIdentifier.scan(data).map(hitDictionary),
                "entropyRegions": EntropyScanner.regions(in: data).map(regionDictionary),
                "stats": UtilityBelt.stats(data)] as NSDictionary
    }

    func carve(_ path: String) -> NSArray {
        let data = try? ToolBelt.readData(path)
        guard let data else { return [["error": "cannot read \(path)"]] }
        return (FormatIdentifier.scan(data) + FormatIdentifier.identifyPacker(data)).map(hitDictionary) as NSArray
    }

    func entropyRegions(_ path: String) -> NSArray {
        let data = try? ToolBelt.readData(path)
        guard let data else { return [["error": "cannot read \(path)"]] }
        return EntropyScanner.regions(in: data).map(regionDictionary) as NSArray
    }

    func scanCrypto(_ path: String) -> NSArray {
        let data = try? ToolBelt.readData(path)
        guard let data else { return [["error": "cannot read \(path)"]] }
        return CryptoIdentifier.scan(data).map(hitDictionary) as NSArray
    }

    /// Decrypt options mirror the AutoDecryptor.Options fields an analyst actually sets:
    /// keys (array of strings), ciphers (array of names), maxLines. No artifacts are written
    /// from scripts; results are evidence only.
    func decrypt(_ path: String, _ options: NSDictionary) -> NSArray {
        let data = try? ToolBelt.readData(path)
        guard let data else { return [["error": "cannot read \(path)"]] }
        var decryptorOptions = AutoDecryptor.Options()
        if let names = options["ciphers"] as? [String] {
            guard !names.isEmpty, names.allSatisfy({ Cipher(rawValue: $0) != nil }) else {
                return [["error": "ciphers must contain supported cipher names"]]
            }
            decryptorOptions.ciphers = names.compactMap { Cipher(rawValue: $0) }
        }
        if let maxLines = options["maxLines"] as? Int { decryptorOptions.maxWordlistEntries = min(max(1, maxLines), 1_000_000) }
        let typedKeys = (options["keys"] as? [String]) ?? []
        do {
            return try AutoDecryptor.run(data: data, typedKeys: typedKeys, options: decryptorOptions)
                .map(resultDictionary) as NSArray
        } catch {
            return [["error": error.localizedDescription]]
        }
    }

    func kdf(_ algorithm: String, _ password: String, _ saltHex: String, _ iterations: Int, _ keyLength: Int) -> NSString {
        do {
            guard let salt = Hex.decode(saltHex) else { return "error: salt must be even-length hex" as NSString }
            let key = try KDFReplay.derive(KDFReplayParameters(algorithm: algorithm, password: password,
                                                               salt: salt, iterations: iterations, keyLength: keyLength))
            return Hex.encode(key) as NSString
        } catch {
            return "error: \(error.localizedDescription)" as NSString
        }
    }

    func cyclicPattern(_ length: Int) -> NSString { CyclicPattern.generate(length) as NSString }

    func patternOffset(_ query: String) -> Int { CyclicPattern.offset(of: query) ?? -1 }

    func crc32(_ hex: String) -> UInt32 {
        Hex.decode(hex).map { UtilityBelt.crc32($0) } ?? 0
    }

    func log(_ message: String) {
        guard consoleOutput.count < 128 else { droppedLogLines += 1; return }
        consoleOutput.append(message.count > 2000 ? String(message.prefix(1980)) + "… [truncated]" : message)
    }

    private func hitDictionary(_ hit: CryptoHit) -> [String: Any] {
        ["offset": hit.offset, "algorithm": hit.algorithm, "kind": hit.kind, "confidence": hit.confidence]
    }
    private func hitDictionary(_ hit: FormatHit) -> [String: Any] {
        ["offset": hit.offset, "format": hit.format, "category": hit.category, "note": hit.note ?? ""]
    }
    private func regionDictionary(_ region: EntropyRegion) -> [String: Any] {
        ["offset": region.offset, "length": region.length, "meanEntropy": region.meanEntropy]
    }
    private func resultDictionary(_ result: CandidateResult) -> [String: Any] {
        ["cipher": result.cipher, "keySource": result.keySource, "keyFingerprint": result.keyFingerprint,
         "success": result.success, "score": result.score, "outputLength": result.outputLength,
         "outputPreviewHex": result.outputPreviewHex, "error": result.error ?? "",
         "validators": result.validators.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] }]
    }
}

public final class ScriptConsole {
    let context: JSContext
    let bridge: AxiomScriptBridge
    private var lastException: String?

    public init() {
        context = JSContext()
        bridge = AxiomScriptBridge()
        context.setObject(bridge, forKeyedSubscript: "axiom" as NSString)
        // Surface script errors as failures, not crashes: the console reports, it never dies.
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown script error"
        }
    }

    /// Runs a script; returns (result, console output lines). The script's last expression is
    /// the result. Errors come back as the thrown JS exception text.
    public func run(script: String) -> Result<(String, [String]), AxiomError> {
        bridge.resetOutput()
        lastException = nil
        defer { lastException = nil }
        guard script.utf8.count <= 1024 * 1024 else {
            return .failure(AxiomError.message("Script source limit is 1 MiB."))
        }
        guard let value = context.evaluateScript(script), lastException == nil else {
            return .failure(AxiomError.message(lastException ?? "script evaluation failed"))
        }
        // toString can execute user code, so check its exception channel as well.
        let result = value.toString() ?? "undefined"
        guard lastException == nil else {
            return .failure(AxiomError.message(lastException ?? "result conversion failed"))
        }
        guard result.utf8.count <= 64 * 1024 else {
            return .failure(AxiomError.message("Script result limit is 64 KiB."))
        }
        var output = bridge.consoleOutput
        if bridge.droppedLogLines > 0 { output.append("Truncated: omitted \(bridge.droppedLogLines) log lines.") }
        return .success((result, output))
    }
}
