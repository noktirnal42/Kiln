import Foundation
import CryptoKit
import CommonCrypto

// Transform engine (docs/DECRYPTION_TOOLING.md stage 3): standard decryption transforms applied
// to analyst-selected bytes with analyst-supplied key candidates. All work is in-memory on
// extracted bytes; the analyzed file is never executed and nothing is sent anywhere.

/// Ciphers the auto-decrypter can attempt. Raw cases are the CLI/MCP names.
public enum Cipher: String, Codable, Sendable, CaseIterable {
    case xor
    case rc4
    case aes128ECB = "aes-128-ecb"
    case aes128CBC = "aes-128-cbc"
    case aes256ECB = "aes-256-ecb"
    case aes256CBC = "aes-256-cbc"
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20Poly1305 = "chacha20-poly1305"
    case blowfish64ECB = "blowfish-64-ecb"
    case blowfish64CBC = "blowfish-64-cbc"

    var isAEAD: Bool { self == .aes128GCM || self == .aes256GCM || self == .chacha20Poly1305 }
    var isBlock: Bool { !isAEAD && self != .xor && self != .rc4 }
    var blockSize: Int { (self == .blowfish64ECB || self == .blowfish64CBC) ? 8 : 16 }
    var keyLength: Int {
        switch self {
        case .aes128ECB, .aes128CBC, .aes128GCM: return 16
        case .aes256ECB, .aes256CBC, .aes256GCM: return 32
        case .chacha20Poly1305, .blowfish64ECB, .blowfish64CBC: return 32
        case .rc4: return 16
        case .xor: return 0
        }
    }
}

public enum Transforms {
    /// Repeating-key XOR.
    public static func xor(_ data: Data, key: Data) -> Data {
        guard !key.isEmpty else { return data }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) in
                let keyBytes = [UInt8](key)
                for index in 0..<inRaw.count { outRaw[index] = inRaw[index] ^ keyBytes[index % keyBytes.count] }
            }
        }
        return out
    }

    /// RC4 (KSA + PRGA), implemented natively — CommonCrypto's RC4 misroundtripped in testing.
    /// Verified against the standard test vector: key "Key", plaintext "Plaintext" → BBF316E8D940AF0AD3.
    public static func rc4(_ data: Data, key: Data) -> Data {
        guard !key.isEmpty, !data.isEmpty else { return data }
        var state = (0..<256).map { UInt8($0) }
        let keyBytes = [UInt8](key)
        var j: UInt8 = 0
        for i in 0..<256 {
            j = j &+ state[i] &+ keyBytes[i % keyBytes.count]
            state.swapAt(i, Int(j))
        }
        var out = [UInt8](repeating: 0, count: data.count)
        // PRGA restarts both counters; carrying KSA's j would be a different (broken) cipher.
        var i: UInt8 = 0
        j = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count {
                i &+= 1
                j &+= state[Int(i)]
                state.swapAt(Int(i), Int(j))
                let keystream = state[Int(state[Int(i)] &+ state[Int(j)])]
                out[index] = raw[index] ^ keystream
            }
        }
        return Data(out)
    }

    /// AES/Blowfish ECB/CBC through CommonCrypto. `padded` selects PKCS7; a padded attempt that fails the
    /// padding check reports an error, which the auto-decrypter treats as a cheap structural filter.
    public static func aes(_ data: Data, key: Data, mode: Cipher, padded: Bool, iv: Data?) throws -> Data {
        let algorithm: CCAlgorithm = (mode == .blowfish64ECB || mode == .blowfish64CBC) ? CCAlgorithm(kCCAlgorithmBlowfish) : CCAlgorithm(kCCAlgorithmAES)
        let blockSize = mode.blockSize
        let usesIV = mode == .aes128CBC || mode == .aes256CBC || mode == .blowfish64CBC
        guard key.count == mode.keyLength else { throw AxiomError.message("Key must be \(mode.keyLength) bytes for \(mode.rawValue).") }
        guard !data.isEmpty, data.count % blockSize == 0 else { throw AxiomError.message("Ciphertext length must be a nonzero multiple of \(blockSize) for \(mode.rawValue).") }
        if usesIV {
            guard let iv, iv.count == blockSize else { throw AxiomError.message("CBC needs a \(blockSize)-byte IV.") }
        }
        var options: CCOptions = (mode == .aes128ECB || mode == .aes256ECB || mode == .blowfish64ECB) ? UInt32(kCCOptionECBMode) : 0
        if padded { options |= UInt32(kCCOptionPKCS7Padding) }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            data.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (keyRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    let ivPointer = usesIV ? iv!.withUnsafeBytes { $0.baseAddress } : nil
                    return CCCrypt(CCOperation(kCCDecrypt), algorithm, options,
                                   keyRaw.baseAddress, key.count, ivPointer,
                                   inRaw.baseAddress, data.count, outRaw.baseAddress, outRaw.count, &moved)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw AxiomError.message(padded ? "Padding check failed (wrong key or not PKCS7-padded)." : "Decryption failed (status \(status)).")
        }
        return out.prefix(moved)
    }

    /// AEAD ciphers via CryptoKit. Accepts the combined layout (12-byte nonce || ciphertext || 16-byte tag),
    /// or a supplied nonce with the remainder as ciphertext || tag.
    public static func aead(_ data: Data, cipher: Cipher, key: Data, nonce: Data?) throws -> Data {
        guard key.count == cipher.keyLength else { throw AxiomError.message("Key must be \(cipher.keyLength) bytes for \(cipher.rawValue).") }
        do {
            switch cipher {
            case .aes128GCM, .aes256GCM:
                if let nonce {
                    guard nonce.count == 12 else { throw AxiomError.message("GCM nonce must be 12 bytes.") }
                    guard data.count > 16 else { throw AxiomError.message("Ciphertext too short for an AEAD tag.") }
                    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: data.prefix(data.count - 16), tag: data.suffix(16))
                    return Data(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data()))
                }
                return Data(try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: Data()))
            case .chacha20Poly1305:
                if let nonce {
                    guard nonce.count == 12 else { throw AxiomError.message("ChaCha20 nonce must be 12 bytes.") }
                    guard data.count > 16 else { throw AxiomError.message("Ciphertext too short for an AEAD tag.") }
                    let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: data.prefix(data.count - 16), tag: data.suffix(16))
                    return Data(try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: Data()))
                }
                return Data(try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: Data()))
            default: throw AxiomError.message("\(cipher.rawValue) is not an AEAD cipher.")
            }
        } catch let error as AxiomError { throw error }
        catch { throw AxiomError.message("AEAD open failed: authentication tag did not verify (wrong key or non-AEAD data).") }
    }

    /// Key variants tried for one password-shaped candidate: raw bytes when they already fit,
    /// zero-padded to the cipher's key size, and the SHA-256 digest. Order is cheapest-first.
    public static func keyVariants(for candidate: String, keyLength: Int) -> [Data] {
        let bytes = Data(candidate.utf8)
        var out: [Data] = []
        func add(_ data: Data) { if data.count == keyLength, !out.contains(data) { out.append(data) } }
        if keyLength > 0 {
            add(bytes)
            add(bytes + Data(repeating: 0, count: max(0, keyLength - bytes.count)))
            add(Data(SHA256.hash(data: bytes)))
        }
        return out
    }

    /// IV variants for block modes: zeros and the first block of the ciphertext (the common
    /// "IV prepended to ciphertext" layout, where the caller strips it).
    public static func ivVariants(data: Data, blockSize: Int = 16) -> [Data] {
        var out = [Data(repeating: 0, count: blockSize)]
        if data.count > blockSize { out.append(data.prefix(blockSize)) }
        return out
    }
}
