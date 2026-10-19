import XCTest
import CryptoKit
import CommonCrypto
import Compression
@testable import AxiomCore

// Tool belt tests (docs/DECRYPTION_TOOLING.md, docs/KALI_METASPLOIT_PARITY.md): every module is
// verified against known vectors and round trips; network tests run against the shared stub
// protocol from IntelligenceTests — no real network in the suite.

final class ToolBeltTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-toolbelt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func stubSession() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]; return URLSession(configuration: c) }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
    /// Plaintext that trips the structural validators: known magic, printable body, modest entropy.
    private func plausiblePlaintext(_ length: Int = 128) -> Data {
        Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(String(repeating: "analysis fixture body text ", count: 8).utf8.prefix(length - 8))
    }

    // MARK: Crypto identification

    func testCryptoScanFindsEmbeddedConstantTablesAtExactOffsets() {
        var bytes = [UInt8](repeating: 0, count: 100)
        bytes += [0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
                  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
                  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
                  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75]
        bytes += [UInt8](repeating: 7, count: 68)
        // Full 8-word (32-byte) prefix of the SHA-256 round-constant table, big-endian.
        bytes += [0x42, 0x8a, 0x2f, 0x98, 0x71, 0x37, 0x44, 0x91, 0xb5, 0xc0, 0xfb, 0xcf, 0xe9, 0xb5, 0xdb, 0xa5,
                  0x39, 0x56, 0xc2, 0x5b, 0x59, 0xf1, 0x11, 0xf1, 0x92, 0x3f, 0x82, 0xa4, 0xab, 0x1c, 0x5e, 0xd5]
        bytes += Array("expand 32-byte k".utf8)
        let hits = CryptoIdentifier.scan(Data(bytes))
        XCTAssertEqual(hits.first { $0.offset == 100 }?.algorithm, "AES")
        XCTAssertEqual(hits.first { $0.offset == 100 }?.kind, "S-box")
        XCTAssertEqual(hits.first { $0.offset == 232 }?.algorithm, "SHA-256")
        XCTAssertEqual(hits.first { $0.offset == 264 }?.algorithm, "ChaCha/Salsa")
        XCTAssertEqual(hits.first { $0.offset == 100 }?.confidence, "exact table match")
        XCTAssertEqual(hits.first { $0.offset == 264 }?.confidence, "short constant run", "16-byte constants are honest about their confidence")
    }

    func testCryptoScanFlagsDERSAExponentAndRejectsBareHeuristicWithoutModulus() {
        var derBytes = [UInt8](repeating: 0x11, count: 64) + [0x02, 0x03, 0x01, 0x00, 0x01] + [UInt8](repeating: 0x22, count: 32)
        let derHits = CryptoIdentifier.scan(Data(derBytes))
        let derHit = derHits.first { $0.algorithm == "RSA" }
        XCTAssertEqual(derHit?.confidence, "exact DER sequence")
        // A lone 01 00 01 followed by zeros is not a modulus; the heuristic must stay quiet.
        derBytes += [0x01, 0x00, 0x01] + [UInt8](repeating: 0, count: 256)
        let quiet = CryptoIdentifier.scan(Data(derBytes)).filter { $0.kind.contains("followed by") }
        XCTAssertTrue(quiet.isEmpty || quiet.allSatisfy { $0.offset != 101 })
    }

    // MARK: Entropy discovery

    func testEntropyScoreBounds() {
        XCTAssertLessThan(EntropyScanner.score(Data(repeating: 0, count: 8192)), 0.1)
        XCTAssertGreaterThan(EntropyScanner.score(random(8192)), 7.5)
        XCTAssertEqual(EntropyScanner.score(Data()), 0)
    }

    func testEntropyRegionsIsolateHighEntropyBlob() {
        var data = Data(repeating: 0, count: 8192)
        data += random(16384)
        data += Data(repeating: 0, count: 8192)
        let regions = EntropyScanner.regions(in: data)
        let covering = regions.first { $0.offset <= 12288 && $0.offset + $0.length >= 16384 }
        XCTAssertNotNil(covering, "the random blob must be found as one region")
        XCTAssertGreaterThan(covering!.meanEntropy, 7.0)
        XCTAssertTrue(regions.allSatisfy { $0.length >= 4096 })
    }

    func testEntropyRegionsIgnoreUniformData() {
        XCTAssertTrue(EntropyScanner.regions(in: Data(repeating: 0x41, count: 65536)).isEmpty)
    }

    // MARK: Format carving and identification

    func testFormatScanFindsEmbeddedSignaturesAtExactOffsets() {
        var data = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])           // PNG at 0
        data += Data(repeating: 0, count: 4092)
        data += Data([0x50, 0x4b, 0x03, 0x04])                                       // ZIP at 4100
        data += Data(repeating: 0, count: 1000)
        data += Data([0x1f, 0x8b, 0x08])                                             // gzip at 5104
        let hits = FormatIdentifier.scan(data)
        XCTAssertEqual(hits.first { $0.format.contains("PNG") }?.offset, 0)
        XCTAssertEqual(hits.first { $0.format == "ZIP local file header" }?.offset, 4100)
        XCTAssertEqual(hits.first { $0.format == "gzip" }?.offset, 5104)
        XCTAssertEqual(hits.first { $0.format == "ZIP local file header" }?.category, "archive")
    }

    func testFormatScanFindsFixedOffsetStructures() {
        var data = Data(repeating: 0, count: 2048)
        data.replaceSubrange(1080..<1082, with: Data([0x53, 0xef]))                  // ext superblock
        data.replaceSubrange(510..<512, with: Data([0x55, 0xaa]))                    // MBR signature
        let hits = FormatIdentifier.scan(data)
        XCTAssertEqual(hits.first { $0.format.contains("ext") }?.offset, 1080)
        XCTAssertEqual(hits.first { $0.format == "MBR boot signature" }?.offset, 510)
    }

    func testPackerMarkersCarryRealOffsets() {
        let data = Data(repeating: 0, count: 64) + Data("UPX!".utf8) + Data(repeating: 0xEE, count: 32)
        let hits = FormatIdentifier.identifyPacker(data)
        XCTAssertEqual(hits.map(\.offset), [64])
        XCTAssertEqual(hits.map(\.category), ["packer"])
    }

    // MARK: Validators

    func testValidatorsSeparateStructureFromNoise() {
        let structured = Validators.assess(plausiblePlaintext())
        XCTAssertTrue(structured.first { $0.name == "magic" }!.passed)
        XCTAssertTrue(structured.first { $0.name == "text" }!.passed)
        XCTAssertGreaterThan(Validators.score(structured), 0.65)
        let noise = Validators.assess(random(512))
        XCTAssertFalse(noise.first { $0.name == "magic" }!.passed)
        XCTAssertLessThanOrEqual(Validators.score(noise), 0.15, "noise must not clear the success gate")
    }

    // MARK: Transforms

    func testXORRoundTrip() {
        let key = Data("repeating-key".utf8)
        let plain = plausiblePlaintext(512)
        XCTAssertEqual(Transforms.xor(Transforms.xor(plain, key: key), key: key), plain)
    }

    func testAESCBCTypedKeyRoundTripAndIVPrefixLayout() throws {
        let key = Data("0123456789abcdef".utf8)
        let plain = plausiblePlaintext(80)
        // Encrypt with CommonCrypto (PKCS7); the transform must invert it exactly.
        let iv = Data(repeating: 7, count: 16)
        let encrypted = try Self.cbcEncrypt(plain, key: key, iv: iv)
        let decrypted = try Transforms.aes(encrypted, key: key, mode: .aes128CBC, padded: true, iv: iv)
        XCTAssertEqual(decrypted, plain)
        // A wrong key either fails the padding check or yields garbage; both rejections are valid.
        if let wrong = try? Transforms.aes(encrypted, key: Data(repeating: 9, count: 16), mode: .aes128CBC, padded: true, iv: iv) {
            XCTAssertNotEqual(wrong, plain, "a wrong key never recovers the plaintext")
        }
    }

    func testAESGCMCombinedAndNonceLayoutsRoundTrip() throws {
        let key = random(32)
        let plain = plausiblePlaintext(200)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key))
        XCTAssertEqual(try Transforms.aead(box.combined!, cipher: .aes256GCM, key: key, nonce: nil), plain)
        let split = box.ciphertext + box.tag
        XCTAssertEqual(try Transforms.aead(split, cipher: .aes256GCM, key: key, nonce: Data(box.nonce)), plain)
        var tampered = box.combined!; tampered[20] ^= 0xFF
        XCTAssertThrowsError(try Transforms.aead(tampered, cipher: .aes256GCM, key: key, nonce: nil), "tag must verify")
    }

    func testKeyVariantsCoverRawPaddingAndDigest() throws {
        let raw = Transforms.keyVariants(for: String(repeating: "k", count: 16), keyLength: 16)
        XCTAssertEqual(raw.first, Data(String(repeating: "k", count: 16).utf8))
        let variants = Transforms.keyVariants(for: "short", keyLength: 32)
        XCTAssertTrue(variants.contains(Data("short".utf8) + Data(repeating: 0, count: 27)))
        XCTAssertTrue(variants.contains(Data(SHA256.hash(data: Data("short".utf8)))))
        XCTAssertEqual(Set(variants.map(\.count)), [32], "every variant must fit the cipher's key length")
    }

    static func cbcEncrypt(_ plain: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: plain.count + kCCBlockSizeAES128); var moved = 0
        let status = out.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            plain.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (keyRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    iv.withUnsafeBytes { (ivRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), UInt32(kCCOptionPKCS7Padding),
                                keyRaw.baseAddress, key.count, ivRaw.baseAddress, inRaw.baseAddress, plain.count, outRaw.baseAddress, outRaw.count, &moved)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw AxiomError.message("encrypt failed: \(status)") }
        return out.prefix(moved)
    }

    // MARK: Auto-decrypt orchestrator

    func testAutoDecryptorRecoversXORKeyFromBlobStrings() throws {
        let key = "s3cret-key"
        let plain = plausiblePlaintext(255)
        let ciphertext = Transforms.xor(plain, key: Data(key.utf8))
        // A null byte separates the ciphertext from the key stored alongside it, so the extracted
        // string is exactly the key — the same boundary a carver produces in practice.
        let blob = ciphertext + Data([0x00]) + Data(key.utf8)
        let results = try AutoDecryptor.run(data: blob)
        let hit = try XCTUnwrap(results.first { $0.success && $0.cipher == "xor" })
        XCTAssertTrue(hit.keySource.contains("blob string"), "key must be attributed to its source")
        XCTAssertTrue(hit.validators.contains { $0.name == "magic" && $0.passed })
        XCTAssertFalse(hit.outputPreviewHex.isEmpty)
        XCTAssertNil(hit.error)
        XCTAssertFalse(results.isEmpty)
    }

    func testAutoDecryptorRecoversAESCBCFromTypedKeyWithPrependedIV() throws {
        let key = "0123456789abcdef"
        let plain = plausiblePlaintext(80)
        let iv = Data(repeating: 0, count: 16)
        let encrypted = try Self.cbcEncrypt(plain, key: Data(key.utf8), iv: iv)
        let data = iv + encrypted
        let results = try AutoDecryptor.run(data: data, typedKeys: [key])
        let hit = try XCTUnwrap(results.first { $0.success && $0.cipher == "aes-128-cbc" })
        XCTAssertEqual(hit.padding, "PKCS7")
        XCTAssertNotNil(hit.iv, "the IV variant that worked is fingerprinted")
        XCTAssertEqual(hit.outputLength, 80, "PKCS7 padding is stripped and the prepended IV is skipped")
    }

    func testAutoDecryptorFindsWordlistKeyForAESECB() throws {
        let password = "correct-horse-battery"
        let plain = Data("SQLite format 3\0".utf8) + Data(String(repeating: "x", count: 46).utf8)
        let key = Data(SHA256.hash(data: Data(password.utf8)))
        let ecb = try Self.ecbEncrypt(plain, key: key)
        var options = AutoDecryptor.Options(); options.ciphers = [.aes256ECB]
        let results = try AutoDecryptor.run(data: ecb, wordlist: Data("wrong\n\(password)\nmore\n".utf8), wordlistName: "test-list", options: options)
        let hit = try XCTUnwrap(results.first { $0.success })
        XCTAssertEqual(hit.keySource, "test-list")
        XCTAssertEqual(hit.keyFingerprint.suffix(6), "len=32")
    }

    func testAutoDecryptorWritesProvenanceArtifactOnlyOnRequest() throws {
        let key = "artifact-key"
        let plain = plausiblePlaintext(128)
        let ciphertext = Transforms.xor(plain, key: Data(key.utf8))
        let blob = ciphertext + Data(key.utf8)
        let directory = try tempDir().appendingPathComponent("artifacts").path
        var options = AutoDecryptor.Options(); options.ciphers = [.xor]; options.artifactDirectory = directory
        options.sourcePath = "/tmp/source.bin"; options.sourceSHA256 = String(repeating: "a", count: 64)
        let results = try AutoDecryptor.run(data: blob, options: options)
        let hit = try XCTUnwrap(results.first { $0.success })
        let path = try XCTUnwrap(hit.artifactPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".provenance.json"))
        let provenance = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + ".provenance.json"))) as! [String: String]
        XCTAssertEqual(provenance["sourceSHA256"], String(repeating: "a", count: 64))
        XCTAssertNil(try AutoDecryptor.run(data: blob, options: AutoDecryptor.Options()).first { $0.success }?.artifactPath, "runs without an artifact directory write nothing")
    }

    func testAutoDecryptorReportsNearMissesWithoutSuccessClaims() throws {
        let results = try AutoDecryptor.run(data: random(4096), typedKeys: ["not-the-key"], options: AutoDecryptor.Options())
        XCTAssertFalse(results.contains { $0.success }, "random data must not produce success claims")
        XCTAssertTrue(results.contains { !$0.success }, "near misses stay visible with reasons")
        XCTAssertTrue(results.allSatisfy { $0.keyFingerprint.contains("len=") })
    }

    func testAutoDecryptorAEADViaTypedPasswordDigest() throws {
        let password = "gcm-test-passphrase"
        let key = Data(SHA256.hash(data: Data(password.utf8)))
        let plain = plausiblePlaintext(96)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key))
        var options = AutoDecryptor.Options(); options.ciphers = [.aes256GCM]
        let results = try AutoDecryptor.run(data: box.combined!, typedKeys: [password], options: options)
        let hit = try XCTUnwrap(results.first { $0.success }, "AEAD candidates authenticate on the full ciphertext")
        XCTAssertEqual(hit.cipher, "aes-256-gcm")
        var tampered = box.combined!; tampered[30] ^= 0xFF
        XCTAssertThrowsError(try Transforms.aead(tampered, cipher: .aes256GCM, key: key, nonce: nil), "tag must verify")
    }

    // MARK: Hex helpers

    func testHexWildcardDecodeAndSearch() throws {
        let pattern = try XCTUnwrap(Hex.decodePattern("41 4? 43"))
        XCTAssertEqual(pattern.count, 3); XCTAssertNil(pattern[1])
        let hits = Hex.search(Data("ABCDABCD".utf8), pattern: pattern)
        XCTAssertEqual(hits, [0, 4])
        XCTAssertNil(Hex.decodePattern("41 4"))
        XCTAssertNil(Hex.decodePattern("41 4z"))
        XCTAssertEqual(Hex.encode(Data([0xde, 0xad])), "dead")
    }

    // MARK: Utility belt

    func testCRC32KnownVector() {
        XCTAssertEqual(UtilityBelt.crc32(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(UtilityBelt.crc32(Data()), 0)
    }

    func testDigestsAndStats() {
        let digests = UtilityBelt.digests(Data("abc".utf8))
        XCTAssertEqual(digests["sha256"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(digests["md5"], "900150983cd24fb0d6963f7d28e17f72")
        let stats = UtilityBelt.stats(Data("aaaa".utf8))
        XCTAssertEqual(stats["dominantByte"], "0x61 (4)")
        XCTAssertEqual(stats["crc32"], String(format: "%08x", UtilityBelt.crc32(Data("aaaa".utf8))))
    }

    func testConvertRoundTripsAcrossBasesAndRejectsBadInput() throws {
        XCTAssertEqual(try UtilityBelt.convert("255", from: 10, to: 16), "0xff")
        XCTAssertEqual(try UtilityBelt.convert("0xff", from: 16, to: 2), "11111111")
        XCTAssertEqual(try UtilityBelt.convert("0b1010", from: 2, to: 10), "10")
        XCTAssertEqual(try UtilityBelt.convert("-10", from: 10, to: 16), "-0xa")
        XCTAssertEqual(try UtilityBelt.convert("17", from: 8, to: 10), "15")   // octal 17 = decimal 15
        XCTAssertThrowsError(try UtilityBelt.convert("ff", from: 10, to: 16))   // 'f' invalid in base 10
        XCTAssertThrowsError(try UtilityBelt.convert("12", from: 9, to: 10))    // base 9 not supported
    }

    func testHexDataRoundTripAndRejectsOddLength() throws {
        XCTAssertEqual(UtilityBelt.dataToHex(Data([0xde, 0xad, 0xbe, 0xef])), "deadbeef")
        XCTAssertEqual(try UtilityBelt.hexToData("DE AD be ef"), Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertThrowsError(try UtilityBelt.hexToData("abc"))
        XCTAssertThrowsError(try UtilityBelt.hexToData("zz"))
    }

    func testWildcardSearchFindsWithAndWithoutWildcardsAndRejectsBadTokens() throws {
        let data = Data([0x41, 0x42, 0x99, 0x44, 0x41, 0x42, 0x00, 0x44])
        XCTAssertEqual(try UtilityBelt.wildcardSearch(data, pattern: "41 42 ?? 44"), [0, 4])
        XCTAssertEqual(try UtilityBelt.wildcardSearch(data, pattern: "41 42 99 44"), [0])
        XCTAssertEqual(try UtilityBelt.wildcardSearch(data, pattern: "ff"), [])
        XCTAssertThrowsError(try UtilityBelt.wildcardSearch(data, pattern: "zz"))
        XCTAssertThrowsError(try UtilityBelt.wildcardSearch(data, pattern: ""))
    }

    // MARK: ZIP reader (T5 foundation)

    /// Builds a real, byte-exact ZIP: local headers + stored/deflated data + central directory + EOCD.
    private func buildZip(_ files: [(name: String, content: Data, deflate: Bool)]) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
        func deflateRaw(_ data: Data) -> Data {
            guard !data.isEmpty else { return Data() }
            var buffer = [UInt8](repeating: 0, count: data.count + 128)
            let capacity = buffer.count
            let written = buffer.withUnsafeMutableBufferPointer { outBuf -> Int in
                data.withUnsafeBytes { inBuf -> Int in
                    compression_encode_buffer(outBuf.baseAddress!, capacity, inBuf.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            return Data(buffer.prefix(written))
        }
        var body: [UInt8] = []
        var central: [UInt8] = []
        var offsets: [Int] = []
        for file in files {
            let nameBytes = Array(file.name.utf8)
            let stored = file.deflate ? deflateRaw(file.content) : file.content
            let method: UInt16 = file.deflate ? 8 : 0
            offsets.append(body.count)
            body += le32(0x04034b50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
                  + le32(0) + le32(UInt32(stored.count)) + le32(UInt32(file.content.count))
                  + le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + stored
        }
        for (index, file) in files.enumerated() {
            let nameBytes = Array(file.name.utf8)
            let stored = file.deflate ? deflateRaw(file.content) : file.content
            let method: UInt16 = file.deflate ? 8 : 0
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
                     + le32(0) + le32(UInt32(stored.count)) + le32(UInt32(file.content.count))
                     + le16(UInt16(nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                     + le32(UInt32(offsets[index])) + nameBytes
        }
        let centralOffset = body.count
        var out = body + central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(UInt16(files.count)) + le16(UInt16(files.count))
             + le32(UInt32(central.count)) + le32(UInt32(centralOffset)) + le16(0)
        return Data(out)
    }

    func testZipReaderListsAndExtractsStoredAndDeflatedEntriesByteExact() throws {
        let readme = Data("hello zip world".utf8)
        let big = Data(repeating: 0x41, count: 5000) + Data("the quick brown fox".utf8) + Data(repeating: 0x42, count: 3000)
        let zip = buildZip([("README.txt", readme, false), ("big.bin", big, true)])
        let entries = try ZipReader.entries(zip)
        XCTAssertEqual(entries.map(\.name), ["README.txt", "big.bin"])
        XCTAssertEqual(entries[0].method, 0); XCTAssertEqual(entries[1].method, 8)
        let extractedReadme = try ZipReader.extract(zip, entry: entries[0])
        XCTAssertEqual(extractedReadme, readme)
        let extractedBig = try ZipReader.extract(zip, entry: entries[1])
        XCTAssertEqual(extractedBig, big)
    }

    func testZipReaderRejectsNonZipAndFindsEntryByName() throws {
        XCTAssertThrowsError(try ZipReader.entries(Data("not a zip".utf8)))
        let zip = buildZip([("a.txt", Data("A".utf8), false), ("b.txt", Data("B".utf8), false)])
        let entries = try ZipReader.entries(zip)
        XCTAssertEqual(ZipReader.entry(named: "b.txt", in: entries)?.uncompressedSize, 1)
        XCTAssertNil(ZipReader.entry(named: "missing.txt", in: entries))
    }

    func testZipReaderOnARealFile() throws {
        let dir = try tempDirDF()
        let source = dir.appendingPathComponent("payload.c")
        try "int main(void){return 0;}".write(to: source, atomically: true, encoding: .utf8)
        let zipPath = dir.appendingPathComponent("real.zip")
        _ = try ProcessRunner.run("/usr/bin/zip", ["-j", zipPath.path, source.path])
        let data = try Data(contentsOf: zipPath)
        let entries = try ZipReader.entries(data)
        XCTAssertEqual(entries.map(\.name), ["payload.c"])
        let extracted = try ZipReader.extract(data, entry: entries[0])
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "int main(void){return 0;}")
    }

    // MARK: DEX (T5)

    /// QA/hello.dex is a real classes.dex (built with the Android SDK's d8 from a small Java class
    /// with a field, an instance method and a static main) checked in so this test needs no
    /// external SDK at test time.
    func testDexFileParsesARealCompiledDexFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("QA/hello.dex")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("QA/hello.dex fixture missing") }
        let data = try Data(contentsOf: url)
        let listing = try DexFile.parse(data)
        XCTAssertTrue(listing.header.version.hasPrefix("0"))
        XCTAssertTrue(listing.classes.contains { $0.name == "com.example.app.Hello" })
        XCTAssertTrue(listing.methods.contains { $0.className == "com.example.app.Hello" && $0.name == "add" })
        XCTAssertTrue(listing.methods.contains { $0.className == "com.example.app.Hello" && $0.name == "main" })
        XCTAssertTrue(listing.fields.contains { $0.className == "com.example.app.Hello" && $0.name == "counter" && $0.typeName == "int" })
        let helloClass = listing.classes.first { $0.name == "com.example.app.Hello" }
        XCTAssertEqual(helloClass?.superclassName, "java.lang.Object")
    }

    func testDexFileRejectsNonDexAndTruncatedData() {
        XCTAssertThrowsError(try DexFile.parse(Data("not a dex".utf8)))
        XCTAssertThrowsError(try DexFile.parse(Data(repeating: 0, count: 50)))
    }

    func testDexTypeDescriptorToName() {
        XCTAssertEqual(DexFile.typeDescriptorToName("Lcom/example/app/Hello;"), "com.example.app.Hello")
        XCTAssertEqual(DexFile.typeDescriptorToName("I"), "int", "primitives map to their names")
        XCTAssertEqual(DexFile.typeDescriptorToName("Z"), "boolean")
        XCTAssertEqual(DexFile.typeDescriptorToName("[Ljava/lang/String;"), "[Ljava/lang/String;")
    }

    func testDexUleb128DecodesKnownValues() {
        XCTAssertEqual(DexFile.uleb128(Data([0x00]), 0)?.value, 0)
        XCTAssertEqual(DexFile.uleb128(Data([0x7f]), 0)?.value, 127)
        XCTAssertEqual(DexFile.uleb128(Data([0x80, 0x01]), 0)?.value, 128)
        XCTAssertEqual(DexFile.uleb128(Data([0xe5, 0x8e, 0x26]), 0)?.value, 624485)   // the canonical LEB128 spec example
    }

    // MARK: Android resource table (T5)

    func testAndroidResourcesParsesARealPackageHeaderAndTypeEntries() throws {
        // Build a minimal but structurally real ARSC: table header -> global string pool (empty) -> one package
        // with a type-name pool, a key-name pool, and one RES_TABLE_TYPE chunk with two simple entries.
        let typeNames = buildStringPool(["string"])
        let keyNames = buildStringPool(["app_name", "hello"])
        let globalPool = buildStringPool([])

        // Two entries, each: ResTable_entry{size=8,u16 flags=0,u32 key} with no following value (size says 8, entry body is just that).
        func entry(key: UInt32) -> [UInt8] { le16(8) + le16(0) + le32(key) }
        let entries = entry(key: 0) + entry(key: 1)
        let entryOffsets = le32(0) + le32(UInt32(8))   // second entry starts after the first 8-byte entry
        let config = le32(32) + [UInt8](repeating: 0, count: 28)   // ResTable_config: size=32, then 28 zero bytes (no qualifiers)
        let typeHeader: [UInt8] = [UInt8(1), UInt8(0)] + le16(0) + le32(2) + le32(UInt32(20 + config.count + entryOffsets.count))
        let typeChunkBody: [UInt8] = typeHeader + config + entryOffsets + entries
        let typeChunk: [UInt8] = le16(0x0201) + le16(20) + le32(UInt32(8 + typeChunkBody.count)) + typeChunkBody

        var packageName: [UInt8] = Array("com.example.app".utf16).flatMap { le16($0) }
        packageName += [UInt8](repeating: 0, count: 256 - packageName.count)
        let packageHeaderFixed = le32(0x7f) + packageName   // id=0x7f (the standard app package id) + 128 UTF-16 units (256 bytes)
        let typeStringsOffsetField = 12 + 256 + 4 + 4 + 4 + 4   // offset (from package chunk start) where typeStrings pool will be placed
        let typeStringsOffset = UInt32(typeStringsOffsetField)
        let keyStringsOffset = typeStringsOffset + UInt32(typeNames.count)
        let packageTail = le32(typeStringsOffset) + le32(0) + le32(keyStringsOffset) + le32(0)
        let packageBody: [UInt8] = packageHeaderFixed + packageTail + typeNames + keyNames + typeChunk
        let packageChunk: [UInt8] = le16(0x0200) + le16(UInt16(284)) + le32(UInt32(8 + packageBody.count)) + packageBody

        let tableBody: [UInt8] = globalPool + packageChunk
        let table: [UInt8] = le16(0x0002) + le16(12) + le32(UInt32(12 + tableBody.count)) + le32(1) + tableBody

        let parsed = try AndroidResources.parse(Data(table))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].packageName, "com.example.app")
        XCTAssertEqual(parsed[0].packageId, 0x7f)
        XCTAssertEqual(parsed[0].entries.count, 2)
        XCTAssertEqual(Set(parsed[0].entries.map(\.key)), ["app_name", "hello"])
        XCTAssertTrue(parsed[0].entries.allSatisfy { $0.type == "string" })
        XCTAssertEqual(parsed[0].entries.first?.id, (0x7f << 24) | (1 << 16) | 0)
    }

    func testAndroidResourcesRejectsNonARSC() {
        XCTAssertThrowsError(try AndroidResources.parse(Data("not arsc".utf8)))
    }

    // MARK: Android binary XML (T5)

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    private func le32s(_ v: Int32) -> [UInt8] { le32(UInt32(bitPattern: v)) }

    /// Builds a real UTF-8 AXML string pool chunk (computes offsets, doesn't hardcode them).
    private func buildStringPool(_ strings: [String]) -> [UInt8] {
        var stringData: [UInt8] = []
        var offsets: [UInt32] = []
        func length8(_ n: Int) -> [UInt8] { n < 0x80 ? [UInt8(n)] : [UInt8(0x80 | (n >> 8)), UInt8(n & 0xff)] }
        for string in strings {
            offsets.append(UInt32(stringData.count))
            let bytes = Array(string.utf8)
            stringData += length8(bytes.count) + length8(bytes.count) + bytes + [0]
        }
        let headerSize = 28
        let stringsStart = UInt32(headerSize + offsets.count * 4)
        var chunk: [UInt8] = []
        let body = offsets.flatMap { le32($0) } + stringData
        let total = UInt32(headerSize) + UInt32(body.count)
        chunk += le16(0x0001) + le16(UInt16(headerSize)) + le32(total)
        chunk += le32(UInt32(strings.count)) + le32(0) + le32(0x100) + le32(stringsStart) + le32(0)
        chunk += body
        return chunk
    }

    private func buildStartElement(name nameIndex: Int32, attributes: [(ns: Int32, name: Int32, rawValue: Int32, dataType: UInt8, value: Int32)]) -> [UInt8] {
        var chunk: [UInt8] = le32s(-1) + le32s(nameIndex) + le16(20) + le16(20) + le16(UInt16(attributes.count)) + le16(0) + le16(0) + le16(0)
        for attribute in attributes { chunk += le32s(attribute.ns) + le32s(attribute.name) + le32s(attribute.rawValue) + le16(8) + [0, attribute.dataType] + le32s(attribute.value) }
        let total = UInt32(8 + 8 + chunk.count)   // top header(8) + lineNumber/comment(8) + the rest
        return le16(0x0102) + le16(16) + le32(total) + le32s(0) + le32s(-1) + chunk
    }
    private func buildEndElement(name nameIndex: Int32) -> [UInt8] {
        let body = le32s(-1) + le32s(nameIndex)
        return le16(0x0103) + le16(16) + le32(UInt32(8 + 8 + body.count)) + le32s(0) + le32s(-1) + body
    }

    func testAndroidXMLParsesARealManifestLikeDocument() throws {
        let strings = ["manifest", "package", "com.example.app", "application", "android:name", ".MainActivity"]
        let pool = buildStringPool(strings)
        let manifestStart = buildStartElement(name: 0, attributes: [(ns: -1, name: 1, rawValue: 2, dataType: 3, value: -1)])
        let applicationStart = buildStartElement(name: 3, attributes: [(ns: -1, name: 4, rawValue: 5, dataType: 3, value: -1)])
        let applicationEnd = buildEndElement(name: 3)
        let manifestEnd = buildEndElement(name: 0)
        let body = pool + manifestStart + applicationStart + applicationEnd + manifestEnd
        let document = le16(0x0003) + le16(8) + le32(UInt32(8 + body.count)) + body
        let events = try AndroidXML.parse(Data(document))
        XCTAssertEqual(events.count, 4)
        guard case .startElement(let name1, _, let attrs1) = events[0] else { return XCTFail("expected start element") }
        XCTAssertEqual(name1, "manifest")
        XCTAssertEqual(attrs1.first?.name, "package"); XCTAssertEqual(attrs1.first?.value, "com.example.app"); XCTAssertEqual(attrs1.first?.dataType, "string")
        guard case .startElement(let name2, _, let attrs2) = events[1] else { return XCTFail("expected start element") }
        XCTAssertEqual(name2, "application")
        XCTAssertEqual(attrs2.first?.name, "android:name"); XCTAssertEqual(attrs2.first?.value, ".MainActivity")
        guard case .endElement(let endName1, _) = events[2] else { return XCTFail("expected end element") }
        XCTAssertEqual(endName1, "application")
        guard case .endElement(let endName2, _) = events[3] else { return XCTFail("expected end element") }
        XCTAssertEqual(endName2, "manifest")
    }

    func testAndroidXMLRejectsNonAXMLAndTruncatedData() {
        XCTAssertThrowsError(try AndroidXML.parse(Data("not axml".utf8)))
        XCTAssertThrowsError(try AndroidXML.parse(Data([0x03, 0x00, 0x08, 0x00])))
    }

    func testAndroidXMLStringPoolHandlesLongStringsNeedingTwoByteLength() throws {
        let long = String(repeating: "x", count: 200)   // forces the 2-byte (high-bit) length encoding
        let strings = ["root", long]
        let pool = buildStringPool(strings)
        let rootStart = buildStartElement(name: 0, attributes: [])
        let rootEnd = buildEndElement(name: 0)
        let body = pool + rootStart + rootEnd
        let document = le16(0x0003) + le16(8) + le32(UInt32(8 + body.count)) + body
        let events = try AndroidXML.parse(Data(document))
        XCTAssertEqual(events.count, 2)
        // Confirm the long string itself decodes correctly via the string pool directly.
        let decoded = try AndroidXML.parseStringPool(Data(pool), at: 0, headerSize: 28)
        XCTAssertEqual(decoded[1], long)
    }

    // MARK: Capture analysis (T6)

    /// Builds a real, byte-exact classic pcap: global header + N Ethernet/IPv4/TCP-or-UDP packets.
    private func buildPcap(_ frames: [(srcPort: UInt16, dstPort: UInt16, proto: UInt8, payload: [UInt8], reversed: Bool)]) -> Data {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
        var out: [UInt8] = le32(0xa1b2c3d4) + [2, 0, 4, 0] + le32(0) + le32(0) + le32(65535) + le32(1)
        var timestamp: UInt32 = 1_700_000_000
        for frame in frames {
            var packet: [UInt8] = Array(repeating: 0xAA, count: 6) + Array(repeating: 0xBB, count: 6) + be16(0x0800)   // Ethernet: dst, src, type=IPv4
            let transportHeaderLength = frame.proto == 6 ? 20 : 8
            let totalLength = UInt16(20 + transportHeaderLength + frame.payload.count)
            let srcIP: [UInt8] = frame.reversed ? [10, 0, 0, 2] : [10, 0, 0, 1]
            let dstIP: [UInt8] = frame.reversed ? [10, 0, 0, 1] : [10, 0, 0, 2]
            packet += [0x45, 0x00] + be16(totalLength) + be16(0) + [0x40, 0x00, 0x40, frame.proto] + be16(0) + srcIP + dstIP   // IPv4, no options, checksum left 0 (not validated by the reader)
            if frame.proto == 6 {
                packet += be16(frame.srcPort) + be16(frame.dstPort) + be32(1) + be32(0) + [0x50, 0x18] + be16(1024) + be16(0) + be16(0)   // TCP, data offset 5, flags ACK|PSH
            } else {
                packet += be16(frame.srcPort) + be16(frame.dstPort) + be16(UInt16(8 + frame.payload.count)) + be16(0)   // UDP
            }
            packet += frame.payload
            out += le32(timestamp) + le32(0) + le32(UInt32(packet.count)) + le32(UInt32(packet.count)) + packet
            timestamp += 1
        }
        return Data(out)
    }

    func testPcapReaderParsesRealGlobalAndPerPacketHeaders() throws {
        let data = buildPcap([(srcPort: 51000, dstPort: 443, proto: 6, payload: Array("hello".utf8), reversed: false),
                               (srcPort: 51000, dstPort: 443, proto: 6, payload: Array("world!".utf8), reversed: false),
                               (srcPort: 52000, dstPort: 53, proto: 17, payload: [0xde, 0xad], reversed: false)])
        let (linkType, packets) = try PcapReader.packets(in: data)
        XCTAssertEqual(linkType, 1)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets[0].capturedLength, packets[0].originalLength)
        XCTAssertEqual(packets[1].timestamp, packets[0].timestamp + 1)
    }

    func testPcapReaderRejectsNonPcapAndTruncatedFiles() {
        XCTAssertThrowsError(try PcapReader.packets(in: Data("not a pcap".utf8)))
        var data = buildPcap([(srcPort: 1, dstPort: 2, proto: 6, payload: [1, 2, 3], reversed: false)])
        data.removeLast(5)   // truncate mid-packet: declared length now runs past EOF
        XCTAssertThrowsError(try PcapReader.packets(in: data))
    }

    func testDissectEthernetReadsRealTCPAndUDPLayersIncludingPayloadOffset() throws {
        let data = buildPcap([(srcPort: 51000, dstPort: 443, proto: 6, payload: Array("hello".utf8), reversed: false),
                               (srcPort: 52000, dstPort: 53, proto: 17, payload: [0xde, 0xad], reversed: false)])
        let (_, packets) = try PcapReader.packets(in: data)
        let tcp = PcapReader.dissectEthernet(data, at: packets[0].offset, length: packets[0].capturedLength)
        XCTAssertEqual(tcp.sourceIP, "10.0.0.1"); XCTAssertEqual(tcp.destIP, "10.0.0.2")
        XCTAssertEqual(tcp.sourcePort, 51000); XCTAssertEqual(tcp.destPort, 443)
        XCTAssertEqual(tcp.ipProtocol, "TCP")
        XCTAssertEqual(Set(tcp.tcpFlags ?? []), ["ACK", "PSH"])
        let payload = data.subdata(in: (data.startIndex + tcp.payloadOffset!)..<(data.startIndex + tcp.payloadOffset! + tcp.payloadLength!))
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")

        let udp = PcapReader.dissectEthernet(data, at: packets[1].offset, length: packets[1].capturedLength)
        XCTAssertEqual(udp.ipProtocol, "UDP"); XCTAssertEqual(udp.sourcePort, 52000); XCTAssertEqual(udp.destPort, 53)
        let udpPayload = data.subdata(in: (data.startIndex + udp.payloadOffset!)..<(data.startIndex + udp.payloadOffset! + udp.payloadLength!))
        XCTAssertEqual([UInt8](udpPayload), [0xde, 0xad])
    }

    func testDissectEthernetNeverCrashesOnShortOrNonIPPackets() {
        let short = Data([1, 2, 3])
        let dissection = PcapReader.dissectEthernet(short, at: 0, length: short.count)
        XCTAssertNil(dissection.sourceIP)
    }

    func testStreamReassemblyGroupsByFourTupleBothDirectionsTogether() throws {
        let data = buildPcap([(srcPort: 51000, dstPort: 443, proto: 6, payload: Array("abc".utf8), reversed: false),
                               (srcPort: 443, dstPort: 51000, proto: 6, payload: Array("de".utf8), reversed: true),   // real reply: both IP and port swapped
                               (srcPort: 52000, dstPort: 53, proto: 17, payload: [1], reversed: false)])
        let (_, packets) = try PcapReader.packets(in: data)
        let flows = StreamReassembly.flows(data, packets: packets)
        XCTAssertEqual(flows.count, 2)
        let tcpFlow = flows.first { $0.destPort == 443 || $0.sourcePort == 443 }
        XCTAssertEqual(tcpFlow?.packetCount, 2)
        XCTAssertEqual(tcpFlow?.byteCount, 5, "both directions' payload bytes summed under one flow")
    }

    // MARK: Dump forensics (T10)

    private func tempDirDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-df-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Embeds a real compiled Mach-O at a nonzero offset inside a padded "dump" and checks the
    /// computed extent matches the real file size exactly, and extraction reproduces the real bytes.
    func testListModulesFindsRealMachOInsideADumpAndComputesExactSize() throws {
        let dir = try tempDirDF()
        let source = dir.appendingPathComponent("f.c"), binary = dir.appendingPathComponent("f")
        try "int main(void){return 42;}".write(to: source, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/clang", ["-o", binary.path, source.path])
        let machO = try Data(contentsOf: binary)
        var dump = Data(repeating: 0xAA, count: 512)
        dump.append(machO)
        dump.append(Data(repeating: 0xBB, count: 256))   // trailing junk the extent must not include
        let modules = DumpForensics.listModules(dump)
        let found = modules.first { $0.offset == 512 }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.format, "Mach-O 64-bit")
        XCTAssertEqual(found?.size, machO.count, "computed extent must match the real on-disk Mach-O size exactly")
        let extracted = try DumpForensics.extractModule(dump, offset: 512, size: found!.size!)
        XCTAssertEqual(extracted, machO)
    }

    func testMachOSizeRejectsGarbageAndTruncatedData() {
        XCTAssertNil(DumpForensics.machOSize(Data([0, 1, 2, 3]), at: 0))
        XCTAssertNil(DumpForensics.machOSize(Data(repeating: 0, count: 8), at: 0))
    }

    func testElfSizeOnARealElfObjectMatchesFileSizeOrIsAtLeastThatLarge() throws {
        let dir = try tempDirDF()
        let source = dir.appendingPathComponent("f.c"), object = dir.appendingPathComponent("f.o")
        try "int add(int a,int b){return a+b;}".write(to: source, atomically: true, encoding: .utf8)
        guard (try? ProcessRunner.run("/usr/bin/clang", ["-target", "x86_64-unknown-linux-gnu", "-c", "-o", object.path, source.path])) != nil else {
            throw XCTSkip("cross ELF target unavailable")
        }
        let elf = try Data(contentsOf: object)
        let size = DumpForensics.elfSize(elf, at: 0)
        XCTAssertNotNil(size)
        XCTAssertGreaterThanOrEqual(size!, elf.count - 64, "section header table should account for nearly all of the file")
    }

    func testParseCoreReadsElfCoreLoadSegmentsAndFlagsTruncation() {
        var elf = Data(count: 64 + 56)
        elf.replaceSubrange(0..<4, with: [0x7f, 0x45, 0x4c, 0x46]); elf[4] = 2; elf[5] = 1
        func put(_ v: UInt64, _ at: Int, _ n: Int) { for i in 0..<n { elf[at + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) } }
        put(4, 16, 2); put(64, 32, 8); put(56, 54, 2); put(1, 56, 2)
        put(1, 64, 4); put(6, 68, 4); put(120, 72, 8); put(0x7000_0000, 80, 8); put(4096, 96, 8); put(8192, 104, 8)
        let core = DumpForensics.parseCore(elf)
        XCTAssertEqual(core?.format, "ELF64 core")
        XCTAssertEqual(core?.regions.first, DumpForensics.CoreRegion(virtualAddress: 0x7000_0000, memorySize: 8192, fileOffset: 120, fileSize: 4096, flags: 6, truncated: true))
        put(1, 16, 2)   // ET_REL is not a core
        XCTAssertNil(DumpForensics.parseCore(elf))
    }

    func testParseCoreReadsMachOCoreSegmentsAndRejectsExecutables() {
        var m = Data(count: 32 + 72)
        func put(_ v: UInt64, _ at: Int, _ n: Int) { for i in 0..<n { m[at + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) } }
        put(0xfeedfacf, 0, 4); put(4, 12, 4); put(1, 16, 4); put(72, 20, 4)
        put(0x19, 32, 4); put(72, 36, 4); put(0x1_0000_0000, 56, 8); put(0x4000, 64, 8); put(104, 72, 8); put(0, 80, 8); put(3, 92, 4)
        let core = DumpForensics.parseCore(m)
        XCTAssertEqual(core?.format, "Mach-O 64 core")
        XCTAssertEqual(core?.regions.count, 1)
        XCTAssertEqual(core?.regions.first?.virtualAddress, 0x1_0000_0000)
        XCTAssertEqual(core?.regions.first?.flags, 3)
        put(2, 12, 4)   // MH_EXECUTE
        XCTAssertNil(DumpForensics.parseCore(m))
        XCTAssertNil(DumpForensics.parseCore(Data([1, 2, 3])))
    }

    func testExtractModuleRejectsOutOfRangeAndOversizedRequests() throws {
        let data = Data(repeating: 0, count: 100)
        XCTAssertThrowsError(try DumpForensics.extractModule(data, offset: 90, size: 20))
        XCTAssertThrowsError(try DumpForensics.extractModule(data, offset: -1, size: 10))
        XCTAssertEqual(try DumpForensics.extractModule(data, offset: 10, size: 10).count, 10)
    }

    func testScanPointersFindsAlignedInRangeValuesOnly() {
        var bytes = [UInt8](repeating: 0, count: 64)
        let inRange: UInt64 = 0x1000_0010   // within arm64UserSpaceRange
        withUnsafeBytes(of: inRange.littleEndian) { bytes.replaceSubrange(16..<24, with: $0) }
        let outOfRange: UInt64 = 0x10   // below the range
        withUnsafeBytes(of: outOfRange.littleEndian) { bytes.replaceSubrange(32..<40, with: $0) }
        let misaligned: UInt64 = 0x1000_0020
        withUnsafeBytes(of: misaligned.littleEndian) { bytes.replaceSubrange(17..<25, with: $0) }   // unaligned copy, should be invisible at stride 8
        let hits = DumpForensics.scanPointers(Data(bytes))
        XCTAssertEqual(hits, [16])
    }

    // MARK: Wordlist catalog and store

    func testWordlistDownloadPinsHashAndRefusesUpstreamChanges() async throws {
        let content = Data("password1\npassword2\n".utf8)
        let pinned = sha(content)
        StubProtocol.handler = { _ in (200, [:], content) }
        let store = WordlistStore(directory: try tempDir(), session: stubSession())
        let entry = WordlistEntry(name: "test-list", category: "passwords", license: "MIT", sourceURL: "https://stub.test/list.txt", sizeBytes: 21, notes: "")
        let url = try await store.download(entry)
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertEqual(try store.installed()["test-list"], pinned, "first verified download pins the hash")
        XCTAssertEqual(try store.verifiedData(named: "test-list"), content)
        var altered = content; altered[0] ^= 0xFF
        StubProtocol.handler = { _ in (200, [:], altered) }
        do { _ = try await store.download(entry); XCTFail("upstream change must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("pinned SHA-256")) }
        XCTAssertEqual(try Data(contentsOf: url), content, "a refused download leaves the pinned file untouched")
    }

    func testWordlistStoreRejectsNonHTTPSAndBadStatus() async throws {
        let store = WordlistStore(directory: try tempDir(), session: stubSession())
        let http = WordlistEntry(name: "insecure", category: "x", license: "MIT", sourceURL: "http://stub.test/x.txt", sizeBytes: 1, notes: "")
        do { _ = try await store.download(http); XCTFail("non-HTTPS sources are refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
        StubProtocol.handler = { _ in (500, [:], Data()) }
        let https = WordlistEntry(name: "flaky", category: "x", license: "MIT", sourceURL: "https://stub.test/x.txt", sizeBytes: 1, notes: "")
        do { _ = try await store.download(https); XCTFail("server error must surface") }
        catch { XCTAssertTrue(error.localizedDescription.contains("500")) }
        XCTAssertThrowsError(try store.verifiedData(named: "never-installed"))
    }

    // MARK: Bounded loading

    func testReadDataRejectsDirectoriesMissingFilesAndOversize() throws {
        XCTAssertThrowsError(try ToolBelt.readData(try tempDir().path))
        XCTAssertThrowsError(try ToolBelt.readData("/nonexistent/toolbelt"))
        let file = try tempDir().appendingPathComponent("big.bin"); try Data(repeating: 0, count: 32).write(to: file)
        XCTAssertThrowsError(try ToolBelt.readData(file.path, limit: 16))
        XCTAssertEqual(try ToolBelt.readData(file.path).count, 32)
    }

    static func ecbEncrypt(_ plain: Data, key: Data) throws -> Data {
        var out = Data(count: plain.count + kCCBlockSizeAES128); var moved = 0
        let status = out.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            plain.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (keyRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), UInt32(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, key.count, nil, inRaw.baseAddress, plain.count, outRaw.baseAddress, outRaw.count, &moved)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw AxiomError.message("encrypt failed: \(status)") }
        return out.prefix(moved)
    }
}

// MARK: Rule scanner (T3)

final class RuleScannerTests: XCTestCase {
    let sample = Data("SuperApp v1.2 footer".utf8) + Data([0x4d, 0x5a, 0x90, 0x00, 0xaa, 0xbb, 0x04, 0x00, 0x04, 0x00]) + Data(repeating: 0xCC, count: 32)

    func testLiteralRuleWithModifiersAndCondition() throws {
        let source = """
        rule finds_version {
          meta: author = "axiom" severity = "info"
          strings:
            $a = "SuperApp" fullword
            $b = "footer" nocase
          condition:
            $a at 0 and $b and filesize > 10
        }
        """
        let rules = try RuleScanner.compile(source)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].meta["author"], "axiom")
        let matches = RuleScanner.scan(sample, rules: rules)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].strings.first { $0.identifier == "$a" }?.offsets, [0])
    }

    func testWideAndNocaseVariantsMatch() throws {
        let source = """
        rule wide_nocase {
          strings:
            $w = "SUPERAPP" wide nocase
          condition:
            $w
        }
        """
        let wideData = Data("x".utf8) + Data("S\0U\0P\0E\0R\0A\0P\0P\0".utf8)
        XCTAssertEqual(RuleScanner.scan(wideData, rules: try RuleScanner.compile(source)).count, 1)
        let plainData = Data("xxsuperappxx".utf8)
        XCTAssertEqual(RuleScanner.scan(plainData, rules: try RuleScanner.compile(source)).count, 0, "wide-only must not match ASCII")
    }

    func testHexPatternWithWildcardsJumpsAndAlternation() throws {
        let source = """
        rule mz_like {
          strings:
            $mz = { 4D 5A ?? 00 [2] (04|90) }
          condition:
            $mz at 20
        }
        """
        let matches = RuleScanner.scan(sample, rules: try RuleScanner.compile(source))
        XCTAssertEqual(matches.first?.strings.first?.offsets, [20], "4D 5A 90 00 ?? ?? 04 00 …: [2] skips two bytes then 04 matches")
    }

    func testConditionSubsetOfThemAndUintComparison() throws {
        let source = """
        rule two_of_three {
          strings:
            $a = "Super" ascii
            $b = { 4D 5A }
            $c = "absent-string"
          condition:
            2 of ($a, $b, $c) and uint16(20) == 0x5A4D
        }
        """
        // uint16(20) reads bytes 20..21 = 4D 5A → little-endian 0x5A4D.
        let matches = RuleScanner.scan(sample, rules: try RuleScanner.compile(source))
        XCTAssertEqual(matches.count, 1)
        let allRule = try RuleScanner.compile("rule all { strings: $a = \"Super\" $b = \"footer\" condition: all of them }")
        XCTAssertEqual(RuleScanner.scan(sample, rules: allRule).count, 1)
        let noneRule = try RuleScanner.compile("rule none { strings: $a = \"Super\" $b = \"footer\" condition: not any of them }")
        XCTAssertEqual(RuleScanner.scan(Data(), rules: noneRule).count, 1, "not any of them over empty data is true")
    }

    func testUnsupportedSyntaxIsACompileErrorNeverASilentMatch() {
        XCTAssertThrowsError(try RuleScanner.compile("rule x { strings: $a = \"a\" condition: $a for * of them }"))
        XCTAssertThrowsError(try RuleScanner.compile("rule x { strings: $a = \"a\" private }"))
        XCTAssertThrowsError(try RuleScanner.compile("no rules here"))
        XCTAssertThrowsError(try RuleScanner.compile("rule x { strings: $a = { [2] 4D } condition: $a }"), "leading jumps are outside the subset")
    }

    // MARK: Recipes (stage 6)

    func testRecipeSaveReplayAndBatchRoundTrip() throws {
        let key = "recipe-key-123"
        let plain = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(String(repeating: "replay body ", count: 12).utf8)
        let ciphertext = Transforms.xor(plain, key: Data(key.utf8))
        let blob = ciphertext + Data([0x00]) + Data(key.utf8)
        let report = try AutoDecryptor.runReport(data: blob, options: AutoDecryptor.Options())
        let winner = try XCTUnwrap(report.winner)
        let recipeWithKey = RecipePlayer.makeRecipe(name: "roundtrip", winner: winner, includeKey: true)
        XCTAssertTrue(recipeWithKey.containsKeyMaterial)
        let encoded = try JSONEncoder().encode(recipeWithKey)
        let decoded = try JSONDecoder().decode(DecryptRecipe.self, from: encoded)
        let (result, output) = try RecipePlayer.apply(decoded, to: blob)
        XCTAssertTrue(result.success)
        XCTAssertEqual(output.prefix(plain.count), plain, "replay reproduces the plaintext; the file tail is untouched bytes")
        XCTAssertEqual(result.keySource, "recipe:roundtrip")
        // A recipe saved without key material demands the key again; a wrong key is refused by fingerprint.
        let recipeWithoutKey = RecipePlayer.makeRecipe(name: "keyless", winner: winner, includeKey: false)
        XCTAssertThrowsError(try RecipePlayer.apply(recipeWithoutKey, to: blob))
        XCTAssertThrowsError(try RecipePlayer.apply(recipeWithoutKey, to: blob, typedKey: Data("wrong".utf8)))
        let (retry, retryOutput) = try RecipePlayer.apply(recipeWithoutKey, to: blob, typedKey: Data(key.utf8))
        XCTAssertTrue(retry.success); XCTAssertEqual(retryOutput.prefix(plain.count), plain)
    }

    // MARK: Cyclic patterns and gadget search (T9)

    func testCyclicPatternOffsetsAreExactAtAllPositions() {
        // One full period plus slack: valid offsets reach the end of the period.
        let pattern = CyclicPattern.generate(CyclicPattern.period + 16)
        for probe in ["Aa0", "a0A", "0Aa", "Ba1", "Zz9", "Aa0A", "a1Aa", "z9Aa"] {
            guard let offset = CyclicPattern.offset(of: probe) else { return XCTFail("no offset for \(probe)") }
            let region = pattern[pattern.index(pattern.startIndex, offsetBy: offset)...]
            XCTAssertTrue(region.hasPrefix(probe), "\(probe) at \(offset) → \(region.prefix(8))")
        }
        XCTAssertNil(CyclicPattern.offset(of: "0000"))
        XCTAssertNil(CyclicPattern.offset(of: String(repeating: "A", count: 32)))
        // Register bytes as they appear in a crash dump, both endiannesses of the same value.
        let little = CyclicPattern.offset(ofBytes: [0x41, 0x61, 0x30, 0x41])   // "Aa0A"
        let big = CyclicPattern.offset(ofBytes: [0x41, 0x30, 0x61, 0x41])      // "A0aA" reversed
        XCTAssertEqual(little, 0)
        XCTAssertNotNil(big)
    }

    func testGadgetSearchFindsChainsAndBreaksAtControlFlow() {
        let assembly = """
        0000000100001000\tsub\tsp, sp, #0x20
        0000000100001004\tpop\tx29, x30
        0000000100001008\tret
        000000010000100c\tbl\t0x100003000
        0000000100001010\tnop
        0000000100001014\tret
        """
        let gadgets = GadgetSearch.search(assembly: assembly, depth: 3)
        XCTAssertTrue(gadgets.contains { $0.instructions == ["sub\tsp, sp, #0x20", "pop\tx29, x30", "ret"] && $0.address == "0000000100001000" })
        XCTAssertTrue(gadgets.contains { $0.instructions == ["nop", "ret"] }, "the walk-back stops at the bl control transfer")
        XCTAssertFalse(gadgets.contains { $0.instructions.contains("bl\t0x100003000") }, "control transfers must not appear mid-chain")
        let x86 = GadgetSearch.search(assembly: "000000000004\tretq\n000000000008\tret", depth: 2, ending: "ret")
        XCTAssertEqual(x86.count, 2, "retq and ret both end gadgets via prefix match")
    }
}

// MARK: Stage 5 ML: features, artifact, transforms, integration hook (docs/ML_MODELS_PLAN.md)

final class CipherClassifierTests: XCTestCase {
    func testRC4StandardVector() {
        // RFC-class test vector: key "Key", plaintext "Plaintext" → BBF316E8D940AF0AD3.
        let ciphertext = Transforms.rc4(Data("Plaintext".utf8), key: Data("Key".utf8))
        XCTAssertEqual(Hex.encode(ciphertext), "bbf316e8d940af0ad3")
        XCTAssertEqual(Transforms.rc4(ciphertext, key: Data("Key".utf8)), Data("Plaintext".utf8), "RC4 is its own inverse")
    }

    func testBlowfishECBRoundTripThroughAutoDecryptor() throws {
        let key = String(repeating: "k", count: 32)
        let plain = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 0x41, count: 24)
        let encrypted = try Transforms.aes(plain, key: Data(key.utf8), mode: .blowfish64ECB, padded: true, iv: nil).count > 0 ? Self.blowfishEncrypt(plain, key: Data(key.utf8)) : Data()
        let results = try AutoDecryptor.run(data: encrypted, typedKeys: [key])
        let hit = try XCTUnwrap(results.first { $0.success && $0.cipher == "blowfish-64-ecb" })
        XCTAssertEqual(hit.outputLength, 32)
    }

    static func blowfishEncrypt(_ plain: Data, key: Data) -> Data {
        var out = Data(count: plain.count + 16); var moved = 0
        let status = out.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            plain.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (keyRaw: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmBlowfish), UInt32(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, key.count, nil, inRaw.baseAddress, plain.count, outRaw.baseAddress, outRaw.count, &moved)
                }
            }
        }
        precondition(status == CCCryptorStatus(kCCSuccess))
        return out.prefix(moved)
    }

    func testFeatureVectorIsDeterministicDimensionalAndDistinct() {
        let layout = FeatureLayout()
        let text = Data("ordinary text function with loops and lookups".utf8)
        let noise = Data((0..<2048).map { UInt8(($0 * 31) & 0xFF) })
        let a = FeatureExtractor.extract(text)
        let b = FeatureExtractor.extract(text)
        XCTAssertEqual(a, b, "extraction is deterministic")
        XCTAssertEqual(a.count, layout.dimension)
        XCTAssertEqual(a[0..<256].reduce(0, +), 1.0, accuracy: 1e-9, "histogram is a distribution")
        XCTAssertNotEqual(FeatureExtractor.extract(noise), a, "classes must produce different vectors")
    }

    func testModelValidationRejectsInconsistentArtifacts() {
        let layout = FeatureLayout()
        var model = CipherClassifierModel(name: "broken", classes: ["aes", "unknown"], layout: layout, weights: [[Double](repeating: 0, count: layout.dimension)], bias: [0, 0])
        XCTAssertThrowsError(try CipherClassifier.validate(model), "weight rows must match class count")
        model.weights = [[Double](repeating: 0, count: 3), [Double](repeating: 0, count: 3)]
        XCTAssertThrowsError(try CipherClassifier.validate(model), "feature dimensions must match the layout")
        model.weights = [[Double](repeating: 0, count: layout.dimension), [Double](repeating: 0, count: layout.dimension)]
        XCTAssertNoThrow(try CipherClassifier.validate(model))
    }

    func testBundledPlaceholderIsInertUntilAGatePassingArtifactLands() throws {
        let model = try XCTUnwrap(CipherClassifier.bundled(), "the resource bundle must ship the artifact slot")
        let suggestions = CipherClassifier.classify(Data("anything".utf8), model: model)
        XCTAssertTrue(suggestions.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
        XCTAssertTrue(CipherClassifier.ciphers(for: "not-a-class").isEmpty)
    }

    func testClassifierHookAddsAndTagsCiphersTheSweepWouldMiss() throws {
        // Restricted sweep (rc4 only) + AES-CBC blob: only the classifier hook makes the aes
        // candidates exist, and the winning result must carry the provenance tag.
        let password = "hook-key-material"
        let key = Data(SHA256.hash(data: Data(password.utf8)))
        let plain = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(String(repeating: "body ", count: 18).utf8)
        let iv = Data(repeating: 3, count: 16)
        let aesPart = try ToolBeltTests.cbcEncrypt(plain, key: key, iv: iv)
        // Block-aligned blob: IV || ciphertext, so the prepended-IV offset variant lands exactly.
        let blob = iv + aesPart
        let layout = FeatureLayout()
        let toy = CipherClassifierModel(name: "toy-aes", classes: ["aes", "unknown"], layout: layout,
                                        weights: [[Double](repeating: 0, count: layout.dimension), [Double](repeating: 0, count: layout.dimension)],
                                        bias: [0, 0], trainingNotes: "hand-built integration fixture, not a trained model")
        var options = AutoDecryptor.Options()
        options.ciphers = [.rc4]
        options.classifier = { data in CipherClassifier.classify(data, model: toy) }
        let report = try AutoDecryptor.runReport(data: blob, typedKeys: [password], options: options)
        let hit = try XCTUnwrap(report.results.first { $0.success && $0.cipher.hasPrefix("aes") }, "the hook must add the suggested cipher to the sweep")
        XCTAssertEqual(hit.mlHypothesis?.contains("classifier"), true, "provenance records the model's role")
        XCTAssertEqual(hit.mlHypothesis?.contains("aes"), true)
        // The tag says hypothesis; the validator evidence is what promoted the result.
        XCTAssertTrue(hit.validators.contains { $0.name == "magic" && $0.passed })
    }

    func testClassifierHookStaysSilentWhenConstantsArePresent() throws {
        // An AES S-box in the bytes means the constant scan answers first; the hook must not tag.
        let sboxPrefix: [UInt8] = [0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
                                   0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
                                   0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
                                   0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
                                   0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
                                   0xeb, 0x27, 0xb2, 0x75]
        var blob = sboxPrefix + [UInt8](repeating: 0xEE, count: 192)
        let layout = FeatureLayout()
        let toy = CipherClassifierModel(name: "toy", classes: ["aes", "unknown"], layout: layout,
                                        weights: [[Double](repeating: 0, count: layout.dimension), [Double](repeating: 0, count: layout.dimension)],
                                        bias: [0, 0])
        var options = AutoDecryptor.Options()
        options.ciphers = [.rc4]
        options.classifier = { _ in [CipherSuggestion(className: "aes", confidence: 1.0)] }
        let report = try AutoDecryptor.runReport(data: Data(blob), typedKeys: ["no-hit-key"], options: options)
        XCTAssertTrue(report.results.allSatisfy { $0.mlHypothesis == nil }, "constant-table evidence takes precedence; the classifier stays out")
    }
}
