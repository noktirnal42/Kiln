import Foundation
import CryptoKit

// Auto-decrypt orchestrator (docs/DECRYPTION_TOOLING.md stage 3): enumerate key candidates from
// typed input, a wordlist, or the analyzed bytes themselves; run transforms cheap-first on a
// probe; validate survivors structurally; rank. Success is always backed by validator evidence
// and results carry a key fingerprint, never the key material itself.

public struct CandidateResult: Codable, Sendable, Equatable {
    public let cipher: String
    public let keySource: String
    /// SHA-256 prefix plus length of the key that produced this result. Full keys are never
    /// recorded in results, logs, or project data.
    public let keyFingerprint: String
    public let iv: String?
    public let padding: String?
    public let success: Bool
    public let score: Double
    public let validators: [ValidatorResult]
    public let outputLength: Int
    public let outputPreviewHex: String
    public let error: String?
    /// Path of the derived artifact when one was written (CLI only; MCP runs are read-only).
    public let artifactPath: String?
    /// Set when the winning cipher was suggested by the optional ML classifier hook
    /// (docs/ML_MODELS_PLAN.md): records the class and confidence so provenance stays visible.
    /// Always a hypothesis label — the validator gate promoted the result, not the model.
    public let mlHypothesis: String?
}

public struct AutoDecryptor {
    public struct Options: Sendable {
        public var ciphers: [Cipher]?
        /// Wordlist entries tried per run; runs are probe-screened so cost stays linear in candidates.
        public var maxWordlistEntries = 50_000
        /// Key-like strings lifted from the analyzed bytes themselves.
        public var maxBlobStrings = 2_048
        public var maxResults = 256
        /// Score at or above which a candidate is reported as a hit and re-run on the full data.
        public var successGate = 0.65
        public var probeBytes = 4096
        /// When set, confirmed hits are written as derived artifacts with provenance sidecars.
        /// MCP callers leave this nil so the tool stays read-only.
        public var artifactDirectory: String?
        public var sourcePath = ""
        public var sourceSHA256 = ""
        /// Optional cipher-classifier hook (docs/ML_MODELS_PLAN.md stage 5). When present AND the
        /// constant-table scan finds nothing, the classifier's top hypotheses reorder the cipher
        /// sweep and tag results via `mlHypothesis`. Off by default; the validator gate is
        /// unchanged regardless of what the classifier says.
        public var classifier: (@Sendable (Data) -> [CipherSuggestion])?
        public init() {}
    }

    /// Key-like printable strings already in the analyzed bytes — the single most common
    /// real-world case (hardcoded keys, keys in adjacent resources). The floor matches the
    /// string extractor's own minimum so 4–7 byte keys are covered too.
    public static func blobCandidates(in data: Data, limit: Int = 2_048) -> [String] {
        Analyzer.extractStrings(data).filter { $0.value.count >= 4 && $0.value.count <= 128 }.prefix(limit).map(\.value)
    }

    /// Runs the full pipeline. Wordlists are loaded by the caller (streamed files are bounded by
    /// the CLI); everything here operates in memory and never writes unless asked.
    public static func run(data: Data, typedKeys: [String] = [], wordlist: Data? = nil, wordlistName: String = "wordlist", options: Options = .init()) throws -> [CandidateResult] {
        try runReport(data: data, typedKeys: typedKeys, wordlist: wordlist, wordlistName: wordlistName, options: options).results
    }

    public static func runReport(data: Data, typedKeys: [String] = [], wordlist: Data? = nil, wordlistName: String = "wordlist", options: Options = .init()) throws -> RunReport {
        guard !data.isEmpty else { throw AxiomError.message("Nothing to decrypt: the selection is empty.") }
        let ciphers = options.ciphers ?? Cipher.allCases
        let probe = data.prefix(options.probeBytes)
        let blobStrings = blobCandidates(in: data, limit: options.maxBlobStrings)
        var results: [CandidateResult] = []
        var nearMisses: [(result: CandidateResult, score: Double)] = []
        var seen = Set<String>()

        // AEAD transforms must run on the complete ciphertext: the tag authenticates everything,
        // so a probe would reject correct keys. Block and XOR candidates screen on the probe.
        // `offset` skips leading bytes (the common "IV prepended to ciphertext" layout).
        func evaluate(cipher: Cipher, key: Data, keySource: String, iv: Data?, padded: Bool?, offset: Int = 0, onHit: ((Winner, Double) -> Void)? = nil, mlTag: String? = nil) {
            let fingerprint = Self.fingerprint(key)
            let identity = "\(cipher.rawValue)|\(fingerprint)|\(iv.map { Self.fingerprint($0) } ?? "-")|\(padded.map { $0 ? "p" : "r" } ?? "-")|+\(offset)"
            guard !seen.contains(identity) else { return }
            seen.insert(identity)
            let base = cipher.isAEAD ? data : probe
            let subject = offset > 0 ? Data(base.dropFirst(offset)) : base
            let fullSubject = offset > 0 ? Data(data.dropFirst(offset)) : data
            func attempt(_ bytes: Data) throws -> Data {
                switch cipher {
                case .xor: return Transforms.xor(bytes, key: key)
                case .rc4: return Transforms.rc4(bytes, key: key)
                case .aes128CBC, .aes256CBC, .aes128ECB, .aes256ECB, .blowfish64CBC, .blowfish64ECB: return try Transforms.aes(bytes, key: key, mode: cipher, padded: padded ?? true, iv: iv)
                case .aes128GCM, .aes256GCM, .chacha20Poly1305: return try Transforms.aead(bytes, cipher: cipher, key: key, nonce: iv)
                }
            }
            do {
                let decrypted = try attempt(subject)
                let validators = Validators.assess(decrypted)
                let score = Validators.score(validators)
                let paddingLabel = padded.map { $0 ? "PKCS7" : "none" }
                if score >= options.successGate {
                    let full = fullSubject.count == subject.count ? decrypted : try attempt(fullSubject)
                    let fullValidators = Validators.assess(full)
                    let fullScore = Validators.score(fullValidators)
                    let artifactPath = try options.artifactDirectory.map { directory in
                        try writeArtifact(full, cipher: cipher.rawValue, keyFingerprint: fingerprint,
                                          sourcePath: options.sourcePath, sourceSHA256: options.sourceSHA256, directory: directory).path
                    }
                    results.append(result(cipher: cipher, keySource: keySource, fingerprint: fingerprint, iv: iv, paddingLabel: paddingLabel,
                                          success: true, score: fullScore, validators: fullValidators, output: full,
                                          error: nil, artifactPath: artifactPath, mlTag: mlTag))
                    onHit?(Winner(cipher: cipher, key: key, iv: iv, padded: padded, offset: offset, keySource: keySource, score: fullScore), fullScore)
                } else {
                    results.append(result(cipher: cipher, keySource: keySource, fingerprint: fingerprint, iv: iv, paddingLabel: paddingLabel,
                                          success: false, score: score, validators: validators, output: decrypted,
                                          error: nil, artifactPath: nil))
                }
            } catch {
                if nearMisses.count < 32 {
                    nearMisses.append((result(cipher: cipher, keySource: keySource, fingerprint: fingerprint, iv: iv,
                                              paddingLabel: padded.map { $0 ? "PKCS7" : "none" }, success: false, score: 0,
                                              validators: [], output: Data(), error: error.localizedDescription, artifactPath: nil, mlTag: mlTag), 0))
                }
            }
        }

        func result(cipher: Cipher, keySource: String, fingerprint: String, iv: Data?, paddingLabel: String?, success: Bool, score: Double, validators: [ValidatorResult], output: Data, error: String?, artifactPath: String?, mlTag: String? = nil) -> CandidateResult {
            CandidateResult(cipher: cipher.rawValue, keySource: keySource, keyFingerprint: fingerprint, iv: iv.map(Self.fingerprint),
                            padding: paddingLabel, success: success, score: (score * 100).rounded() / 100, validators: validators,
                            outputLength: output.count, outputPreviewHex: Hex.encode(output.prefix(64)), error: error, artifactPath: artifactPath,
                            mlHypothesis: mlTag)
        }

        // Every password-shaped candidate goes through the same path: key variants per cipher,
        // IV variants for CBC, padded and unpadded block attempts.
        var winner: Winner?
        var winnerScore = -1.0
        func recordWinner(_ candidate: Winner, score: Double) {
            if score > winnerScore { winner = candidate; winnerScore = score }
        }
        func tryPassword(_ password: String, _ source: String) {
            for cipher in ciphers where cipher != .xor {
                for key in Transforms.keyVariants(for: password, keyLength: cipher.keyLength) {
                    if cipher.isAEAD {
                        evaluate(cipher: cipher, key: key, keySource: source, iv: nil, padded: nil, offset: 0, onHit: recordWinner)
                    } else if cipher == .rc4 {
                        evaluate(cipher: cipher, key: key, keySource: source, iv: nil, padded: nil, offset: 0, onHit: recordWinner)
                    } else if cipher == .aes128CBC || cipher == .aes256CBC || cipher == .blowfish64CBC {
                        for iv in Transforms.ivVariants(data: probe, blockSize: cipher.blockSize) {
                            // The first-block IV variant pairs with ciphertext that skips its first block.
                            let offset = iv == probe.prefix(cipher.blockSize) ? cipher.blockSize : 0
                            for padded in [true, false] { evaluate(cipher: cipher, key: key, keySource: source, iv: iv, padded: padded, offset: offset, onHit: recordWinner) }
                        }
                    } else {
                        for padded in [true, false] { evaluate(cipher: cipher, key: key, keySource: source, iv: nil, padded: padded, offset: 0, onHit: recordWinner) }
                    }
                }
            }
            if ciphers.contains(.xor), password.count <= 64 { evaluate(cipher: .xor, key: Data(password.utf8), keySource: source, iv: nil, padded: nil, offset: 0, onHit: recordWinner) }
        }

        // Classifier hypotheses (docs/ML_MODELS_PLAN.md): only when the constant-table scan finds
        // nothing — the gap this model exists to fill. Suggested ciphers are swept first and
        // tagged; the sweep itself is unchanged otherwise.
        var suggestedCiphers: [Cipher] = []
        var mlTags: [Cipher: String] = [:]
        if let classifier = options.classifier, CryptoIdentifier.scan(probe).isEmpty {
            for suggestion in classifier(probe) where suggestion.confidence >= 0.5 {
                for cipher in CipherClassifier.ciphers(for: suggestion.className) where !suggestedCiphers.contains(cipher) {
                    suggestedCiphers.append(cipher)
                    mlTags[cipher] = "cipher classifier: \(suggestion.className) \(Int(suggestion.confidence * 100))%"
                }
            }
        }

        // Binary-derived candidates first (highest prior: hardcoded keys live near their data), then typed keys.
        func trySuggestedPassword(_ password: String, _ cipher: Cipher, _ source: String) {
            guard let tag = mlTags[cipher] else { return }
            for key in Transforms.keyVariants(for: password, keyLength: cipher.keyLength) {
                if cipher.isAEAD {
                    evaluate(cipher: cipher, key: key, keySource: source, iv: nil, padded: nil, offset: 0, onHit: recordWinner, mlTag: tag)
                } else if cipher == .rc4 {
                    evaluate(cipher: cipher, key: key, keySource: source, iv: nil, padded: nil, offset: 0, onHit: recordWinner, mlTag: tag)
                } else if cipher == .aes128CBC || cipher == .aes256CBC || cipher == .blowfish64CBC {
                    for iv in Transforms.ivVariants(data: probe, blockSize: cipher.blockSize) {
                        let offset = iv == probe.prefix(cipher.blockSize) ? cipher.blockSize : 0
                        for padded in [true, false] { evaluate(cipher: cipher, key: key, keySource: source, iv: iv, padded: padded, offset: offset, onHit: recordWinner, mlTag: tag) }
                    }
                } else {
                    for padded in [true, false] { evaluate(cipher: cipher, key: key, keySource: source, iv: nil, padded: padded, offset: 0, onHit: recordWinner, mlTag: tag) }
                }
            }
        }
        for password in blobStrings {
            try OperationContext.check()
            for cipher in suggestedCiphers {
                trySuggestedPassword(password, cipher, "blob string")
            }
            tryPassword(password, "blob string")
        }
        for password in typedKeys {
            for cipher in suggestedCiphers {
                trySuggestedPassword(password, cipher, "typed")
            }
            tryPassword(password, "typed")
        }
        // Single-byte XOR sweep: 255 cheap probes covering weak obfuscation.
        if ciphers.contains(.xor) {
            for byte: UInt8 in 1...255 { try OperationContext.check(); evaluate(cipher: .xor, key: Data([byte]), keySource: "single-byte 0x\(String(byte, radix: 16))", iv: nil, padded: nil, offset: 0, onHit: recordWinner) }
        }
        // Wordlist entries last: highest volume, streamed by the caller.
        if let wordlist, !wordlist.isEmpty {
            var tried = 0
            for line in wordlist.split(whereSeparator: { $0 == 10 || $0 == 13 }) {
                try OperationContext.check()
                if tried % 500 == 0 { OperationContext.progress(min(1, Double(tried) / Double(max(1, options.maxWordlistEntries))), "wordlist entry \(tried)") }
                guard tried < options.maxWordlistEntries else { break }
                guard let password = String(data: Data(line), encoding: .utf8), !password.isEmpty, password.count <= 256 else { continue }
                tried += 1
                tryPassword(password, wordlistName)
            }
        }

        let misses = nearMisses.sorted { $0.score > $1.score }.map(\.result)
        return RunReport(results: (results + misses).prefix(options.maxResults).map { $0 }, winner: winner)
    }

    /// One confirmed hit with its full parameters — the input a replayable recipe needs. Keys are
    /// handed to the caller (CLI recipe saving) only; they never appear in CandidateResult or JSON.
    public struct Winner: Sendable {
        public let cipher: Cipher
        public let key: Data
        public let iv: Data?
        public let padded: Bool?
        public let offset: Int
        public let keySource: String
        public let score: Double
    }

    public struct RunReport: Sendable {
        public let results: [CandidateResult]
        public let winner: Winner?
    }

    public static func fingerprint(_ key: Data) -> String {
        String(SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined().prefix(16)) + " len=\(key.count)"
    }

    /// Writes a confirmed hit as a derived artifact with a provenance sidecar. The decrypted bytes
    /// are clearly labeled; they never silently replace the original analysis data.
    public static func writeArtifact(_ output: Data, cipher: String, keyFingerprint: String, sourcePath: String, sourceSHA256: String, directory: String) throws -> URL {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let safe = cipher.replacingOccurrences(of: "/", with: "-")
        let file = URL(fileURLWithPath: directory).appendingPathComponent("decrypted-\(safe)-\(keyFingerprint.prefix(8)).bin")
        try output.write(to: file, options: .atomic)
        let provenance: [String: Any] = ["cipher": cipher, "keyFingerprint": keyFingerprint, "sourcePath": sourcePath,
                                         "sourceSHA256": sourceSHA256, "date": ISO8601DateFormatter().string(from: Date()),
                                         "note": "Derived artifact from Axiom RE auto-decrypt; key material is not recorded."]
        let json = try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: file.path + ".provenance.json"), options: .atomic)
        return file
    }
}

/// Hex helpers shared across the tool belt.
public enum Hex {
    public static func encode(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    /// Decodes a hex byte pattern with `?` nibble wildcards (e.g. `4? 4? 41 42`); `nil` for malformed input.
    public static func decodePattern(_ pattern: String) -> [UInt8?]? {
        let tokens = pattern.split(whereSeparator: { $0 == " " || $0 == "," })
        guard !tokens.isEmpty else { return nil }
        var out: [UInt8?] = []
        for token in tokens {
            let text = String(token)
            guard text.count == 2 else { return nil }
            let first = text.utf8.first!, second = text.utf8.last!
            var byte: UInt8 = 0
            for character in [first, second] {
                if character == UInt8(ascii: "?") { byte = byte << 4; continue }
                guard let value = nibble(character) else { return nil }
                byte = byte << 4 | value
            }
            out.append(text.contains("?") ? nil : byte)
        }
        return out
    }
    static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 0x30...0x39: return character - 0x30
        case 0x61...0x66: return character - 0x61 + 10
        case 0x41...0x46: return character - 0x41 + 10
        default: return nil
        }
    }
    /// Decodes plain hex of any even length (spaces ignored); `nil` for malformed input.
    public static func decode(_ text: String) -> Data? {
        let clean = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var iterator = clean.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let h = nibble(high), let l = nibble(low) else { return nil }
            out.append(h << 4 | l)
        }
        return Data(out)
    }

    /// Searches for a wildcard byte pattern; `nil` entries match any byte. Bounded result count.
    public static func search(_ data: Data, pattern: [UInt8?], limit: Int = 4096) -> [Int] {
        guard !pattern.isEmpty, data.count >= pattern.count else { return [] }
        var hits: [Int] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for start in 0...(raw.count - pattern.count) {
                var matched = true
                for (offset, expected) in pattern.enumerated() {
                    if let expected, raw[start + offset] != expected { matched = false; break }
                }
                if matched {
                    hits.append(start)
                    if hits.count >= limit { return }
                }
            }
        }
        return hits
    }
}
