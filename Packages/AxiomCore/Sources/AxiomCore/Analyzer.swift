import Foundation
import CryptoKit

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        let output = Pipe(); task.standardOutput = output; task.standardError = output
        let capture = Capture()
        output.fileHandleForReading.readabilityHandler = { handle in capture.append(handle.availableData) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
        }
        try OperationContext.check()
        try task.run()
        // If the operation is cancelled, end the whole process tree (Ghidra's launcher script runs the JVM as a child).
        let context = OperationContext.current
        let token = context?.onCancel { ProcessRunner.terminateTree(task) }
        defer { if let token { context?.removeHandler(token) } }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline && context?.isCancelled != true { Thread.sleep(forTimeInterval: 0.05) }
        if context?.isCancelled == true { terminateTree(task); task.waitUntilExit(); throw OperationCancelled() }
        if task.isRunning { task.terminate(); Thread.sleep(forTimeInterval: 0.2); if task.isRunning { kill(task.processIdentifier, SIGKILL) }; task.waitUntilExit(); throw AxiomError.message("Engine timed out after \(Int(timeout)) seconds.") }
        task.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        capture.append(output.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: capture.data, as: UTF8.self)
        guard task.terminationStatus == 0 else { throw AxiomError.message("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(task.terminationStatus)): \(text.suffix(3000))") }
        return text
    }
    /// Parent -> children map from the process table. Deliberately not routed through `run`, which honours cancellation: it must
    /// work while the operation it serves is already cancelled.
    static func processChildren() -> [Int32: [Int32]] {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/ps"); task.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        var children: [Int32: [Int32]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) { children[ppid, default: []].append(pid) }
        }
        return children
    }
    private static let terminationLock = NSLock()
    nonisolated(unsafe) private static var terminated = Set<Int32>()

    /// Ends a process and everything it started. The descendants are snapshotted BEFORE anything is signalled and killed children-first:
    /// once the root dies its children are re-parented away and could no longer be found (Ghidra's launcher script runs the JVM as a
    /// grandchild). SIGTERM first, then SIGKILL for anything still alive after a short grace period. Idempotent per process.
    static func terminateTree(_ task: Process) {
        let root = task.processIdentifier
        guard root > 0 else { return }
        terminationLock.lock(); let first = terminated.insert(root).inserted; terminationLock.unlock()
        guard first else { return }
        var all: [Int32] = [root]
        let children = processChildren()
        var index = 0
        while index < all.count { all.append(contentsOf: children[all[index]] ?? []); index += 1 }
        for pid in all.reversed() { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            for pid in all where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            terminationLock.lock(); terminated.remove(root); terminationLock.unlock()
        }
        // The caller may be about to exit the process: make the escalation not depend on that timer by waiting briefly here.
        for _ in 0..<20 { if all.allSatisfy({ kill($0, 0) != 0 }) { return }; Thread.sleep(forTimeInterval: 0.05) }
        for pid in all where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
    private final class Capture: @unchecked Sendable {
        private var buffer = Data(); private let lock = NSLock()
        func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; let remaining = max(0, 16 * 1024 * 1024 - buffer.count); buffer.append(data.prefix(remaining)) }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}
public enum Analyzer {
    public static func analyzeProject(_ path: String, project: String, home: String, scriptPath: String, arch: String? = nil) throws -> Analysis {
        let initial = try inspect(path, arch: arch)
        try ProjectStore.create(initial, to: project)
        // Retain the native project and engine diagnostics on failure for recovery.
        let result = try ghidra(path, home: home, scriptPath: scriptPath, arch: arch, workspace: engineWorkspace(projectPath: project, projectID: initial.id))
        return try ProjectStore.replace(result, to: project, expectedID: initial.id, expectedRevision: initial.revision, preserveAnnotations: true)
    }
    public static func inspect(_ path: String, arch: String? = nil) throws -> Analysis {
        let original = URL(fileURLWithPath: path).standardizedFileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: original.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw AxiomError.message("Choose a regular binary file.") }
        guard let size = attrs[.size] as? Int, size <= 256 * 1024 * 1024 else { throw AxiomError.message("Import limit is 256 MiB.") }
        // Identity (path, size, SHA-256) always describes the file the analyst chose; engines read the selected slice.
        let resolution = try resolveSlice(original.path, arch: arch)
        defer { resolution.cleanup() }
        let url = URL(fileURLWithPath: resolution.path)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: resolution.slices.isEmpty ? data : try Data(contentsOf: original, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        let format = try ProcessRunner.run("/usr/bin/file", ["-b", url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        var warnings: [String] = []
        let strings = extractStrings(data)
        if strings.count == 20_000 { warnings.append("String listing limited to 20,000 entries.") }
        var sections = "Format metadata requires Mach-O or Ghidra analysis."
        var functions: [FunctionRecord] = []
        if format.contains("Mach-O") {
            sections = (try? ProcessRunner.run("/usr/bin/otool", ["-l", url.path])) ?? "Could not read load commands."
            let listing = try ProcessRunner.run("/usr/bin/otool", ["-tvV", url.path])
            functions = parseAssembly(listing)
            warnings.append("Native inspection uses otool. Decompilation and richer references require Ghidra.")
        } else { warnings.append("Native disassembly supports Mach-O. Configure Ghidra for this format.") }
        let hex = stride(from: 0, to: min(data.count, 4096), by: 16).map { offset in
            let bytes = data[offset..<min(offset + 16, data.count)]
            return String(format: "%08x  ", offset) + bytes.map { String(format: "%02x", $0) }.joined(separator: " ") + "  " + bytes.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        }.joined(separator: "\n")
        if let chosen = resolution.chosen, resolution.slices.count > 1 { warnings.append("Universal binary (\(resolution.slices.joined(separator: ", "))): analyzing the \(chosen) slice. String offsets are relative to that slice.") }
        var result = Analysis(binaryPath: original.path, sha256: hash, size: size, format: format, engine: "Apple otool · native inspection", sections: sections, hex: hex, functions: functions, strings: strings, warnings: warnings)
        if resolution.slices.count > 1 { result.slices = resolution.slices; result.slice = resolution.chosen }
        return result
    }
    public static func extractStrings(_ data: Data) -> [StringRecord] {
        var results: [StringRecord] = []; var start = 0; var run: [UInt8] = []
        for (offset, byte) in data.enumerated() {
            if (32...126).contains(byte) { if run.isEmpty { start = offset }; if run.count < 4096 { run.append(byte) } }
            else { if run.count >= 4 { results.append(StringRecord(offset: start, value: String(decoding: run, as: UTF8.self))) }; run.removeAll(keepingCapacity: true) }
            if results.count >= 20_000 { break }
        }
        if run.count >= 4 && results.count < 20_000 { results.append(StringRecord(offset: start, value: String(decoding: run, as: UTF8.self))) }
        return results
    }
    public static func parseAssembly(_ text: String) -> [FunctionRecord] {
        var result: [FunctionRecord] = []; var name: String?; var lines: [String] = []; var address = ""
        func flush() { if let name, !address.isEmpty { result.append(FunctionRecord(address: address, name: name, assembly: lines.joined(separator: "\n"))) } }
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasSuffix(":"), !line.contains(" "), !line.contains("\t") { flush(); name = String(line.dropLast()); lines = []; address = "" }
            else if name != nil {
                let token = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? ""
                if token.count >= 8, UInt64(token, radix: 16) != nil { if address.isEmpty { address = token }; lines.append(line) }
            }
            if result.count >= 20_000 { break }
        }
        flush(); return result
    }
    /// Upstream Ghidra rejects project locations containing a path component that starts with ".". Checked up front so the analyst gets an actionable message instead of a Java stack trace.
    public static func validateGhidraWorkspace(_ workspace: String) throws {
        let hidden = URL(fileURLWithPath: workspace).standardizedFileURL.pathComponents.filter { $0.hasPrefix(".") && $0 != "/" }
        guard hidden.isEmpty else {
            throw AxiomError.message("Ghidra cannot use a project folder inside a hidden directory (\(hidden.joined(separator: ", "))). Save the Axiom project to a normal, non-hidden folder and run the engine again.")
        }
    }

    /// Where Ghidra's project files for an Axiom project live. Normally `<project>/engine`; when that path has a hidden
    /// component (which Ghidra refuses) the engine files go to a non-hidden per-project folder under Application Support,
    /// and `Analysis.engineProject` records the real location. Analyst data stays in the Axiom project either way.
    public static func engineWorkspace(projectPath: String, projectID: String, supportDirectory: URL? = nil) -> String {
        let preferred = URL(fileURLWithPath: projectPath).appendingPathComponent("engine").path
        if (try? validateGhidraWorkspace(preferred)) != nil { return preferred }
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AxiomRE/engine/\(projectID)").path
    }

    public static func ghidra(_ path: String, home: String, scriptPath: String, arch: String? = nil, workspace: String) throws -> Analysis {
        try validateGhidraWorkspace(workspace)
        var base = try inspect(path, arch: arch)
        let resolution = try resolveSlice(path, arch: arch)
        defer { resolution.cleanup() }
        let launcher = URL(fileURLWithPath: home).appendingPathComponent("support/analyzeHeadless").path
        guard FileManager.default.isExecutableFile(atPath: launcher) else { throw AxiomError.message("Ghidra home must contain support/analyzeHeadless.") }
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let output = URL(fileURLWithPath: workspace).appendingPathComponent("export-\(UUID().uuidString).json").path
        let projectName = "Axiom-" + UUID().uuidString
        let log = try ProcessRunner.run(launcher, [workspace, projectName, "-import", resolution.path, "-scriptPath", scriptPath, "-postScript", "AxiomExport.java", output, "-analysisTimeoutPerFile", "180"], timeout: 240)
        guard FileManager.default.fileExists(atPath: output) else { throw AxiomError.message("Ghidra produced no export. \(log.suffix(2000))") }
        struct Export: Decodable { var functions: [FunctionRecord]; var language: String; var warnings: [String] }
        let attributes = try FileManager.default.attributesOfItem(atPath: output)
        guard (attributes[.size] as? Int ?? 0) <= 64 * 1024 * 1024 else { throw AxiomError.message("Engine export exceeds 64 MiB.") }
        let exported = try JSONDecoder().decode(Export.self, from: Data(contentsOf: URL(fileURLWithPath: output)))
        base.engineProject = URL(fileURLWithPath: workspace).appendingPathComponent(projectName + ".gpr").path
        base.functions = exported.functions; base.engine = "Ghidra · " + exported.language; base.warnings = exported.warnings
        try? FileManager.default.removeItem(atPath: output)
        return base
    }
}
