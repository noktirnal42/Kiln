import XCTest
import CryptoKit
import Darwin
@testable import AxiomCore

// Device bench tests (docs/KALI_METASPLOIT_PARITY.md T7/T8): the serial console runs against a
// real pseudo-terminal (no hardware), the GDB-RSP client against an in-memory stub probe, and
// the KDF replay against published vectors. No real device or network is touched.

final class DeviceBenchTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Serial console over a pseudo-terminal

    func testSerialConsoleCapturesAndSendsOverAPTY() throws {
        // Open master/slave PTY pair; the console talks to the slave like any USB-serial device.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw XCTSkip("posix_openpt unavailable") }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            close(master); throw XCTSkip("PTY unlock failed")
        }
        guard let slaveCPath = ptsname(master) else { close(master); throw XCTSkip("ptsname failed") }
        let slavePath = String(cString: slaveCPath)
        defer { close(master) }

        let console = try DeviceConsole(devicePath: slavePath, baud: 115200, consent: true)
        // The boot log the "device" emits on the master side.
        let bootLog = Data("U-Boot 2023.01 (Oct 12 2026)\nMTK5586 platform boot\ndone, booting kernel\n".utf8)
        bootLog.withUnsafeBytes { _ = write(master, $0.baseAddress, $0.count) }
        let newLines = try console.capture(seconds: 0.5)
        XCTAssertTrue(newLines.contains { $0.contains("U-Boot") })
        XCTAssertTrue(console.lines.contains { $0.contains("booting kernel") })
        XCTAssertEqual(console.search("platform").first?.text.contains("MTK5586"), true)

        // Transmit from the analyst side; the master side receives it, and it lands in the audit.
        try console.send(line: "help")
        var echoed = [UInt8](repeating: 0, count: 5)
        _ = read(master, &echoed, 5)
        XCTAssertEqual(String(decoding: echoed.prefix(4), as: UTF8.self), "help")
        XCTAssertTrue(console.record.notes.contains { $0.contains("sent: help") })
        XCTAssertEqual(console.record.sideEffects, "read-only capture; transmitted lines are logged in notes")
    }

    func testSerialConsoleRefusesWithoutConsent() {
        XCTAssertThrowsError(try DeviceConsole(devicePath: "/dev/tty.usbserial", baud: 115200, consent: false))
    }

    // MARK: GDB-RSP client against an in-memory stub probe

    /// A stub probe: scripted responses to the commands Axiom sends, with correct framing.
    final class StubProbe: GDBTransport, @unchecked Sendable {
        var received: [String] = []
        private var inbox: [UInt8] = []
        var responder: (String) -> String = { _ in "OK" }

        func send(_ bytes: [UInt8]) throws {
            let text = String(decoding: bytes, as: UTF8.self)
            if text == "+" { return }
            guard let start = text.firstIndex(of: "$"), let end = text.firstIndex(of: "#") else { return }
            let command = String(text[text.index(after: start)..<end])
            received.append(command)
            let payload = Array(responder(command).utf8)
            let checksum = payload.reduce(0) { ($0 + Int($1)) & 0xff }
            var packet: [UInt8] = [0x2b, 0x24]
            packet += payload
            packet.append(0x23)
            packet += Array(String(format: "%02x", checksum).utf8)
            inbox += packet
        }

        func receive() throws -> UInt8? { inbox.isEmpty ? nil : inbox.removeFirst() }
        func close() {}
    }

    func testGDBRSPHandshakeRegistersMemoryAndBreakpoints() throws {
        let probe = StubProbe()
        probe.responder = { command in
            switch command {
            case "?": return "T05thread:1;"
            case "g": return String(repeating: "00", count: 33)   // arm64: 33 x 8-byte registers
            case let m where m.hasPrefix("m1000,"): return "deadc0de"   // memory at 0x1000
            default: return "OK"
            }
        }
        let client = try GDBRSPClient(transport: probe, target: "stub:1234", consent: true)
        XCTAssertTrue(try client.haltReason().hasPrefix("T05"))
        XCTAssertEqual(probe.received.first, "?", "the first exchange queries the halt state")
        let registers = try client.readRegisters()
        XCTAssertEqual(registers.count, 33, "hex pairs decode to bytes")
        let memory = try client.readMemory(address: 0x1000, length: 4)
        XCTAssertEqual(memory, [0xde, 0xad, 0xc0, 0xde])
        try client.setBreakpoint(address: 0x8000)
        XCTAssertTrue(probe.received.contains("Z0,8000,1"))
        try client.clearBreakpoint(address: 0x8000)
        XCTAssertTrue(probe.received.contains("z0,8000,1"))
        try client.detach()
        XCTAssertEqual(client.record.ended?.timeIntervalSince(client.record.started) ?? -1, -1, accuracy: 5)
        XCTAssertEqual(client.record.kind, "gdb")
    }

    func testGDBRSPRejectsCorruptChecksumsAndBadMemoryResponses() throws {
        let probe = StubProbe()
        probe.responder = { command in
            if command.hasPrefix("m") { return "E14" }   // probe refuses the read
            return "OK"
        }
        let client = try GDBRSPClient(transport: probe, target: "stub:1234", consent: true)
        XCTAssertThrowsError(try client.readMemory(address: 0x1000, length: 4)) { error in
            XCTAssertTrue(error.localizedDescription.contains("refused"))
        }
        XCTAssertThrowsError(try client.readMemory(address: 0x1000, length: 0), "absurd lengths are refused client-side")
        XCTAssertThrowsError(try GDBRSPClient(transport: probe, target: "stub:1234", consent: false))
    }

    // MARK: Flash-dump import

    func testFlashDumpRecognizesErasedRegionsAndCommonSizes() throws {
        var dump = Data(repeating: 0xFF, count: 8192)
        dump.replaceSubrange(0..<512, with: Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(repeating: 0, count: 508))  // Mach-O at base
        dump.append(Data(repeating: 0x41, count: 4096))   // firmware tail
        let report = FlashDump.analyze(dump, path: "/tmp/dump.bin")
        XCTAssertEqual(report.size, 8192 + 4096)
        XCTAssertEqual(report.sha256.count, 64)
        XCTAssertTrue(report.likelyRegions.contains { $0.evidence.contains("0xFF") }, "erased flash is recognized")
        XCTAssertTrue(report.likelyRegions.contains { $0.guess.contains("Mach-O") })
        XCTAssertTrue(report.likelyRegions.contains { $0.evidence.contains("standard flash part") } == false, "8 KiB+4 KiB is not a real flash part size")
        let sized = FlashDump.analyze(Data(repeating: 0x00, count: 16 * 1024 * 1024), path: "/tmp/dump2.bin")
        XCTAssertTrue(sized.likelyRegions.contains { $0.evidence.contains("standard flash part") })
    }

    // MARK: KDF replay (T8 v1)

    func testPBKDF2KnownVectors() throws {
        // RFC 7914 §11 / widely published PBKDF2-HMAC-SHA256 vectors.
        let vector1 = try KDFReplay.derive(KDFReplayParameters(algorithm: "pbkdf2-sha256", password: "password",
                                                               salt: Data("salt".utf8), iterations: 1, keyLength: 32))
        XCTAssertEqual(Hex.encode(vector1), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let vector2 = try KDFReplay.derive(KDFReplayParameters(algorithm: "pbkdf2-sha256", password: "password",
                                                               salt: Data("salt".utf8), iterations: 2, keyLength: 32))
        XCTAssertEqual(Hex.encode(vector2), "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        let sha1 = try KDFReplay.derive(KDFReplayParameters(algorithm: "pbkdf2-sha1", password: "password",
                                                            salt: Data("salt".utf8), iterations: 1, keyLength: 20))
        XCTAssertEqual(Hex.encode(sha1), "0c60c80f961f0e71f3a9b524af6012062fe037a6")
    }

    func testKDFReplaySweepAndRefusals() throws {
        let parameters = KDFReplayParameters(algorithm: "pbkdf2-sha256", password: "password",
                                             salt: Data("salt".utf8), iterations: 1, keyLength: 32)
        let sweep = try KDFReplay.sweep(base: parameters, rounds: [1, 2, 4])
        XCTAssertEqual(sweep.map(\.iterations), [1, 2, 4])
        XCTAssertEqual(Hex.encode(sweep[1].key), "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertThrowsError(try KDFReplay.derive(KDFReplayParameters(algorithm: "md5-magic", password: "x", salt: Data(), iterations: 1, keyLength: 32)))
        XCTAssertThrowsError(try KDFReplay.derive(KDFReplayParameters(algorithm: "pbkdf2-sha256", password: "x", salt: Data(), iterations: 99_999_999, keyLength: 32)))
        let hkdf = try KDFReplay.derive(KDFReplayParameters(algorithm: "hkdf-sha256", password: "secret", salt: Data("salt".utf8), iterations: 1, keyLength: 16))
        XCTAssertEqual(hkdf.count, 16)
    }
}

// MARK: Emulation session scaffolding (T8 v1)

final class EmulationSessionTests: XCTestCase {
    func testKDFReplayHostRequiresConsentAndAudits() throws {
        let host = KDFReplayHost()
        let parameters = KDFReplayParameters(algorithm: "pbkdf2-sha256", password: "password",
                                             salt: Data("salt".utf8), iterations: 2, keyLength: 32)
        XCTAssertThrowsError(try host.run(.kdfReplay(parameters), consent: EmulationConsent(granted: false, scope: "kdf replay")),
                             "no consent, no emulation")
        let result = try host.run(.kdfReplay(parameters), consent: EmulationConsent(granted: true, scope: "kdf replay"))
        XCTAssertEqual(result.outputHex, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(result.audit.kind, "emulation")
        XCTAssertEqual(result.audit.sideEffects, "none — pure derivation on extracted parameters")
        XCTAssertTrue(result.audit.notes.contains { $0.contains("consent scope: kdf replay") })
    }

    func testHostRefusesOperationsItDoesNotImplement() throws {
        let host = KDFReplayHost()
        // The p-code operation is a roadmap-B case; the v1 host must refuse it, not fake it.
        XCTAssertFalse(host.supports(.pCodeFunction(bytes: Data([1]), base: 0, watchpoints: [])))
        XCTAssertThrowsError(try host.run(.pCodeFunction(bytes: Data([1]), base: 0, watchpoints: []),
                                          consent: EmulationConsent(granted: true, scope: "function")))
    }
}

// MARK: T9 scripting console

final class ScriptConsoleTests: XCTestCase {
    func testPlainHexDecodingPreservesEmptySaltAndRejectsMalformedInput() {
        XCTAssertEqual(Hex.decode(""), Data())
        XCTAssertEqual(Hex.decode("  "), Data())
        XCTAssertEqual(Hex.decode("aB 01"), Data([0xab, 1]))
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("zz"))
        XCTAssertNil(Hex.decode("??"))
    }

    func testScriptOutputIsBoundedAndResetBetweenRuns() throws {
        let console = ScriptConsole()
        let (_, output) = try console.run(script: "for (var i = 0; i < 140; i++) axiom.log('line'); 'ok'").get()
        XCTAssertEqual(output.count, 129)
        XCTAssertTrue(output.last!.contains("omitted 12"))
        let (_, next) = try console.run(script: "axiom.log('next'); 'ok'").get()
        XCTAssertEqual(next, ["next"])
        let (_, longLine) = try console.run(script: "axiom.log('x'.repeat(2500)); 'ok'").get()
        XCTAssertLessThanOrEqual(longLine[0].count, 2000)
        XCTAssertTrue(longLine[0].contains("truncated"))
        XCTAssertThrowsError(try console.run(script: "'x'.repeat(65537)").get())
        XCTAssertThrowsError(try console.run(script: String(repeating: " ", count: 1024 * 1024 + 1)).get())
    }

    func testResultConversionErrorsFailAndNextRunRecovers() throws {
        let console = ScriptConsole()
        XCTAssertThrowsError(try console.run(script: "({toString: function() { throw new Error('conversion failed'); }})").get())
        let (result, _) = try console.run(script: "42").get()
        XCTAssertEqual(result, "42")
    }

    func testDigestReportContainsRealDigestsAndStatistics() {
        let report = UtilityBelt.digestReport(Data("123456789".utf8))
        XCTAssertEqual(report["sha256"], "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225")
        XCTAssertEqual(report["md5"], "25f9e794323b453885f5181f1b624d0b")
        XCTAssertEqual(report["sha1"], "f7c3bc1d808e04732adf679965ccc34ca7ae3441")
        XCTAssertEqual(report["crc32"], "cbf43926")
        XCTAssertEqual(report["size"], "9")
    }

    func testHKDFInvalidOutputLengthsThrowInsteadOfTrapping() {
        for length in [-1, 0, 513, 100000] {
            XCTAssertThrowsError(try KDFReplay.derive(.init(algorithm: "hkdf-sha256", password: "key", salt: Data(), iterations: 1, keyLength: length)))
        }
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testScriptDrivesAnalysisAPIsEndToEnd() throws {
        // A fixture blob with a PNG magic and a known XOR key beside it.
        let key = "scriptkey"
        let plain = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(String(repeating: "console fixture ", count: 8).utf8)
        let ciphertext = Transforms.xor(plain, key: Data(key.utf8))
        let blob = ciphertext + Data([0x00]) + Data(key.utf8)
        let fixture = try tempDir().appendingPathComponent("blob.bin")
        try blob.write(to: fixture)

        let script = """
        var files = ["\(fixture.path)"];
        var triage = axiom.triage(files[0]);
        var patterns = axiom.cyclicPattern(64);
        var offset = axiom.patternOffset("Aa0A");
        var crc = axiom.crc32("313233343536373839");
        var key = axiom.kdf("pbkdf2-sha256", "password", "73616c74", 1, 32);   // salt = "salt" as hex
        var results = axiom.decrypt(files[0], { ciphers: ["xor", "aes-128-cbc"] });
        var hits = [];
        for (var i = 0; i < results.length; i++) { if (results[i].success) hits.push(results[i].cipher); }
        axiom.log("triaged " + triage.size + " bytes");
        [triage.size, offset, crc, key, hits.join(",")].join("|");
        """
        let console = ScriptConsole()
        let (result, output) = try console.run(script: script).get()
        let parts = result.split(separator: "|")
        XCTAssertEqual(parts.count, 5, result)
        XCTAssertEqual(Int(parts[0]), blob.count)
        XCTAssertEqual(Int(parts[1]), 0, "pattern offset Aa0A is 0")
        XCTAssertEqual(Int(parts[2]), 0xCBF43926, "CRC32 of 123456789")
        XCTAssertEqual(parts[3], "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertTrue(parts[4].contains("xor"), "the sweep finds the XOR hit through the console API")
        XCTAssertTrue(output.contains { $0.contains("triaged") })
    }

    func testScriptErrorsSurfaceInsteadOfCrashing() {
        let console = ScriptConsole()
        // Syntax errors come back as failures, never crashes.
        if case .success = console.run(script: "this is not (( javascript") {
            XCTFail("a malformed script must not succeed")
        }
        // Runtime errors surface through the exception channel.
        if case .success(let (result, _)) = console.run(script: "JSON.stringify(axiom.triage('/nonexistent/x'))") {
            XCTAssertTrue(result.contains("cannot read"), "API errors are data, not crashes: \(result)")
        }
        // The last expression is the result.
        if case .success(let (result, _)) = console.run(script: "1 + 2") {
            XCTAssertEqual(result, "3")
        }
    }
}
