import Foundation
import CryptoKit
import CommonCrypto

// Flash-dump import (docs/KALI_METASPLOIT_PARITY.md T7): the file side of flashrom-class work.
// A dump lands as a file; Axiom hashes it, profiles entropy, carves known signatures and fixed-
// offset structures with the existing scanners, and records a dump metadata artifact so the
// analyst can decide where the firmware, NVRAM, and bootloader regions start. Hardware reading
// stays external; layout guesses are labeled as leads, not conclusions.

public struct FlashDumpReport: Codable, Sendable {
    public let path: String
    public let size: Int
    public let sha256: String
    public let entropyRegions: [EntropyRegion]
    public let formatHits: [FormatHit]
    public let cryptoHits: [CryptoHit]
    public let likelyRegions: [LikelyRegion]
}

public struct LikelyRegion: Codable, Sendable {
    public let offset: Int
    public let length: Int
    public let guess: String
    public let evidence: String
}

public enum FlashDump {
    /// Common SPI flash sizes, used to sanity-check dumps against real chips.
    static let commonSizes = [512 * 1024, 1024 * 1024, 2 * 1024 * 1024, 4 * 1024 * 1024,
                              8 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024, 64 * 1024 * 1024,
                              128 * 1024 * 1024, 256 * 1024 * 1024]

    public static func analyze(_ data: Data, path: String) -> FlashDumpReport {
        var likely: [LikelyRegion] = []
        // Erased-flash recognition: 0xFF or 0x00 runs are the two real erase states.
        for (pattern, name) in [(0xff, "erased (0xFF)"), (0x00, "erased (0x00)")] {
            var runStart: Int?
            var index = 0
            let bytes = [UInt8](data.prefix(16 * 1024 * 1024))   // cap the scan; dumps can be large
            while index <= bytes.count {
                let matches = index < bytes.count && bytes[index] == pattern
                if matches, runStart == nil { runStart = index }
                if !matches, let start = runStart {
                    if index - start >= 4096 {
                        likely.append(LikelyRegion(offset: start, length: index - start, guess: name,
                                                   evidence: "contiguous \(pattern == 0xff ? "0xFF" : "0x00") run"))
                    }
                    runStart = nil
                }
                index += 1
            }
        }
        // Bootloader-first heuristic: most SPI layouts put the boot image at offset 0.
        let header = FormatIdentifier.scan(Data(data.prefix(64))).filter { $0.offset == 0 }
        for hit in header {
            likely.insert(LikelyRegion(offset: 0, length: 0, guess: "\(hit.format) at flash base",
                                       evidence: "header magic at offset 0"), at: 0)
        }
        if commonSizes.contains(data.count) {
            likely.insert(LikelyRegion(offset: 0, length: data.count, guess: "common SPI flash size (\(data.count / 1024) KiB)",
                                       evidence: "size matches a standard flash part"), at: 0)
        }
        return FlashDumpReport(path: path, size: data.count,
                               sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                               entropyRegions: EntropyScanner.regions(in: data, minLength: 8192),
                               formatHits: FormatIdentifier.scan(data),
                               cryptoHits: CryptoIdentifier.scan(data),
                               likelyRegions: likely)
    }
}

// KDF replay (docs/KALI_METASPLOIT_PARITY.md T8, v1): the decryption pipeline's static KDF
// replay — PBKDF2/HKDF key derivation re-run on recovered parameters instead of emulating the
// KDF code. This is the first piece of the emulation story: deriving what the device derives,
// on-device, without executing the target. The p-code host remains the roadmap-B integration
// point for arbitrary loops (docs/KALI_METASPLOIT_PARITY.md T8).

public struct KDFReplayParameters: Codable, Sendable, Equatable {
    public var algorithm: String        // "pbkdf2-sha256", "pbkdf2-sha1", "pbkdf2-sha512", "hkdf-sha256"
    public var password: String
    public var salt: Data
    public var iterations: Int
    public var keyLength: Int
    public var info: Data               // HKDF only

    public init(algorithm: String, password: String, salt: Data, iterations: Int, keyLength: Int, info: Data = Data()) {
        self.algorithm = algorithm; self.password = password; self.salt = salt
        self.iterations = iterations; self.keyLength = keyLength; self.info = info
    }
}

public enum KDFReplay {
    public static let supportedAlgorithms = ["pbkdf2-sha1", "pbkdf2-sha256", "pbkdf2-sha512", "hkdf-sha256"]

    /// Derives one key. The output is key material: callers pass it straight into transforms
    /// and never log or persist it.
    public static func derive(_ parameters: KDFReplayParameters) throws -> Data {
        guard parameters.keyLength >= 1, parameters.keyLength <= 512 else {
            throw AxiomError.message("Key length must be 1…512 bytes.")
        }
        let passwordBytes = Array(parameters.password.utf8)
        switch parameters.algorithm {
        case "pbkdf2-sha1", "pbkdf2-sha256", "pbkdf2-sha512":
            let prf: CCPseudoRandomAlgorithm
            switch parameters.algorithm {
            case "pbkdf2-sha1": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            case "pbkdf2-sha256": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            default: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            }
            guard parameters.iterations >= 1, parameters.iterations <= 10_000_000 else {
                throw AxiomError.message("Iteration count must be 1…10,000,000.")
            }
            guard parameters.keyLength >= 1, parameters.keyLength <= 512 else {
                throw AxiomError.message("Key length must be 1…512 bytes.")
            }
            var derived = [UInt8](repeating: 0, count: parameters.keyLength)
            let status = derived.withUnsafeMutableBufferPointer { out -> Int32 in
                passwordBytes.withUnsafeBufferPointer { password in
                    let saltBytes = [UInt8](parameters.salt)
                    return saltBytes.withUnsafeBufferPointer { salt in
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress, password.count,
                                             salt.baseAddress, salt.count, prf, UInt32(parameters.iterations),
                                             out.baseAddress, parameters.keyLength)
                    }
                }
            }
            guard status == kCCSuccess else { throw AxiomError.message("PBKDF2 failed with status \(status).") }
            return Data(derived)
        case "hkdf-sha256":
            guard parameters.iterations == 1 || parameters.iterations == 0 else {
                throw AxiomError.message("HKDF has no iteration count; omit it or pass 1.")
            }
            let symmetric = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(parameters.password.utf8)),
                                                   salt: parameters.salt, info: parameters.info,
                                                   outputByteCount: parameters.keyLength)
            return symmetric.withUnsafeBytes { Data($0) }
        default:
            throw AxiomError.message("Unsupported KDF \"\(parameters.algorithm)\". Supported: \(supportedAlgorithms.joined(separator: ", ")).")
        }
    }

    /// Iteration sweep: derives the key for each round count (firmware vendors iterate KDFs
    /// across versions; the right round count is discovered by which key decrypts).
    public static func sweep(base parameters: KDFReplayParameters, rounds: [Int]) throws -> [(iterations: Int, key: Data)] {
        try rounds.map { rounds in
            var parameters = parameters
            parameters.iterations = rounds
            return (rounds, try derive(parameters))
        }
    }
}
