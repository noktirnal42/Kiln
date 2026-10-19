import Foundation
import CryptoKit

// Recipes (docs/DECRYPTION_TOOLING.md stage 6): a confirmed decryption is recorded as a
// replayable, auditable recipe that can be applied to related binaries — successive firmware
// versions from the same vendor being the canonical case. A recipe embeds key material ONLY
// when the analyst explicitly saves it (the file is user-owned and says so on its face);
// otherwise it records the parameters and the key fingerprint, and replay requires the key
// again. Replay verifies the SHA-256 of whatever key it uses before touching data, so a typo
// is refused, not silently misapplied.

public struct DecryptRecipe: Codable, Sendable {
    public var version = 1
    public var name: String
    public var cipher: String
    /// Full SHA-256 of the working key, for verification on replay.
    public var keySHA256: String
    /// Present only when the analyst explicitly chose to save it.
    public var key: Data?
    public var keyLength: Int
    public var iv: Data?
    public var padding: String?
    /// Offset of the ciphertext within source files (e.g. after a prepended IV).
    public var cipherOffset: Int
    public var keySource: String
    public var notes: String
    public var created: Date
    public var sourceSHA256: String?

    public var containsKeyMaterial: Bool { key != nil }
}

public struct BatchOutcome: Codable, Sendable {
    public let path: String
    public let success: Bool
    public let score: Double
    public let magic: String?
    public let outputLength: Int
    public let artifactPath: String?
    public let error: String?
    public init(path: String, success: Bool, score: Double, magic: String?, outputLength: Int, artifactPath: String?, error: String?) {
        self.path = path; self.success = success; self.score = score; self.magic = magic
        self.outputLength = outputLength; self.artifactPath = artifactPath; self.error = error
    }
}

public enum RecipePlayer {
    /// Builds a recipe from a confirmed hit. Key material is embedded only on explicit request.
    public static func makeRecipe(name: String, winner: AutoDecryptor.Winner, includeKey: Bool, notes: String = "", sourceSHA256: String? = nil) -> DecryptRecipe {
        DecryptRecipe(name: name, cipher: winner.cipher.rawValue,
                      keySHA256: SHA256.hash(data: winner.key).map { String(format: "%02x", $0) }.joined(),
                      key: includeKey ? winner.key : nil, keyLength: winner.key.count,
                      iv: winner.iv, padding: winner.padded.map { $0 ? "PKCS7" : "none" },
                      cipherOffset: winner.offset, keySource: winner.keySource, notes: notes,
                      created: Date(), sourceSHA256: sourceSHA256)
    }

    /// Applies a recipe deterministically: one transform on the target bytes, then validators.
    /// No candidate search happens here — replay is fast and exactly reproducible.
    public static func apply(_ recipe: DecryptRecipe, to data: Data, typedKey: Data? = nil, artifactDirectory: String? = nil, sourcePath: String = "") throws -> (result: CandidateResult, output: Data) {
        guard let cipher = Cipher(rawValue: recipe.cipher) else {
            throw AxiomError.message("Recipe references unknown cipher \"\(recipe.cipher)\".")
        }
        let key = typedKey ?? recipe.key
        guard let key else {
            throw AxiomError.message("Recipe \"\(recipe.name)\" was saved without key material; supply --key to replay it.")
        }
        let keyHash = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        guard keyHash == recipe.keySHA256 else {
            throw AxiomError.message("Supplied key does not match the recipe fingerprint (\(recipe.keySHA256.prefix(16))…); refusing to apply a wrong key.")
        }
        guard cipher == .xor || key.count == cipher.keyLength else {
            throw AxiomError.message("Key must be \(cipher.keyLength) bytes for \(cipher.rawValue).")
        }
        guard recipe.cipherOffset >= 0, recipe.cipherOffset <= data.count else {
            throw AxiomError.message("Recipe offset \(recipe.cipherOffset) is outside the target file.")
        }
        let subject = recipe.cipherOffset > 0 ? Data(data.dropFirst(recipe.cipherOffset)) : data
        let decrypted: Data
        do {
            switch cipher {
            case .xor: decrypted = Transforms.xor(subject, key: key)
            case .rc4: decrypted = Transforms.rc4(subject, key: key)
            case .aes128CBC, .aes256CBC, .aes128ECB, .aes256ECB, .blowfish64CBC, .blowfish64ECB:
                decrypted = try Transforms.aes(subject, key: key, mode: cipher, padded: recipe.padding != "none", iv: recipe.iv)
            case .aes128GCM, .aes256GCM, .chacha20Poly1305:
                decrypted = try Transforms.aead(subject, cipher: cipher, key: key, nonce: recipe.iv)
            }
        } catch {
            return (CandidateResult(cipher: recipe.cipher, keySource: "recipe:\(recipe.name)", keyFingerprint: AutoDecryptor.fingerprint(key),
                                    iv: recipe.iv.map(AutoDecryptor.fingerprint), padding: recipe.padding, success: false, score: 0,
                                    validators: [], outputLength: 0, outputPreviewHex: "", error: error.localizedDescription, artifactPath: nil,
                                    mlHypothesis: nil), Data())
        }
        let validators = Validators.assess(decrypted)
        let score = Validators.score(validators)
        let success = score >= 0.65
        var artifactPath: String?
        if success, let directory = artifactDirectory {
            artifactPath = try AutoDecryptor.writeArtifact(decrypted, cipher: recipe.cipher, keyFingerprint: AutoDecryptor.fingerprint(key),
                                                           sourcePath: sourcePath, sourceSHA256: recipe.sourceSHA256 ?? "", directory: directory).path
        }
        return (CandidateResult(cipher: recipe.cipher, keySource: "recipe:\(recipe.name)", keyFingerprint: AutoDecryptor.fingerprint(key),
                                iv: recipe.iv.map(AutoDecryptor.fingerprint), padding: recipe.padding, success: success, score: score,
                                validators: validators, outputLength: decrypted.count, outputPreviewHex: Hex.encode(decrypted.prefix(64)),
                                error: nil, artifactPath: artifactPath, mlHypothesis: nil), decrypted)
    }
}
