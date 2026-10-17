# SuperMetaApp — Reverse Engineering Console Module Specification

## Overview

The **Reverse Engineering Console Module** provides a native macOS reverse engineering workbench comparable to Ghidra and Axiom RE. It imports binaries without executing them, drives Ghidra headless and radare2 as analysis engines, persists analyst annotations, and exposes all operations to agents via the Model Context Protocol (MCP).

---

## Module Identity

```json
{
  "identifier": "com.supermeta.reverseengineering",
  "displayName": "Reverse Engineering Console",
  "version": "1.0.0",
  "category": "security",
  "icon": "magnifyingglass.circle.fill",
  "requiredCapabilities": [
    "fileSystem.read",
    "process.spawn",
    "memoryInspection",
    "debuggerAttach",
    "kernelDebug"
  ],
  "provides": [
    "binaryInspector",
    "disassembler",
    "decompiler",
    "functionAnalyzer",
    "stringAnalyzer",
    "cryptoScanner",
    "entropyAnalyzer",
    "formatCarver",
    "autoDecryptor",
    "ruleScanner",
    "gadgetFinder",
    "dumpForensics",
    "firmwareAnalyzer",
    "deviceConsole",
    "scriptingConsole",
    "projectStore"
  ]
}
```

---

## Architecture

```
ReverseEngineeringModule/
├── Module.swift
├── BinaryInspector/
│   ├── BinaryInspectorView.swift
│   ├── FileImporter.swift
│   ├── ArchitectureDetector.swift
│   ├── FormatIdentifier.swift
│   └── SectionViewer.swift
├── Disassembler/
│   ├── DisassemblyView.swift
│   ├── GhidraBridge/
│   │   ├── GhidraHeadlessManager.swift
│   │   ├── GhidraProjectManager.swift
│   │   ├── GhidraAnalyzer.swift
│   │   └── GhidraDecompiler.swift
│   ├── Radare2Bridge/
│   │   ├── Radare2Manager.swift
│   │   ├── Radare2Analyzer.swift
│   │   └── Radare2Decompiler.swift
│   ├── CapstoneBridge/
│   │   └── CapstoneDisassembler.swift
│   └── InstructionViewer.swift
├── Decompiler/
│   ├── DecompilerView.swift
│   ├── PseudocodeRenderer.swift
│   ├── VariableRenamer.swift
│   ├── TypeManager.swift
│   └── CommentManager.swift
├── FunctionAnalyzer/
│   ├── FunctionListView.swift
│   ├── FunctionDetailView.swift
│   ├── CallGraphView.swift
│   ├── CallerCalleeView.swift
│   ├── CFGViewer.swift
│   └── FunctionMatcher.swift
├── StringAnalyzer/
│   ├── StringListView.swift
│   ├── StringDetailView.swift
│   ├── StringSearch.swift
│   ├── EncodingDetector.swift
│   └── ReferenceFinder.swift
├── CryptoScanner/
│   ├── CryptoScannerView.swift
│   ├── ConstantDetector.swift
│   │   ├── AESDetector.swift
│   │   ├── SHADetector.swift
│   │   ├── MD5Detector.swift
│   │   ├── KeccakDetector.swift
│   │   ├── BlowfishDetector.swift
│   │   ├── ChaChaDetector.swift
│   │   ├── CRC32Detector.swift
│   │   └── RSADetector.swift
│   └── KeyFinder.swift
├── EntropyAnalyzer/
│   ├── EntropyView.swift
│   ├── SlidingWindowEntropy.swift
│   ├── HighEntropyRegionFinder.swift
│   └── EntropyHeatmap.swift
├── FormatCarver/
│   ├── FormatCarverView.swift
│   ├── SignatureDatabase.swift
│   ├── CarverEngine.swift
│   ├── SupportedFormats.swift
│   └── ExtractedFileViewer.swift
├── AutoDecryptor/
│   ├── AutoDecryptorView.swift
│   ├── TransformEngine.swift
│   │   ├── XORTransform.swift
│   │   ├── AESTransform.swift
│   │   ├── AESGCMTransform.swift
│   │   ├── ChaCha20Poly1305Transform.swift
│   │   └── CustomTransform.swift
│   ├── KeyGenerator.swift
│   ├── WordlistManager.swift
│   ├── CandidateRanker.swift
│   └── RecipeManager.swift
├── RuleScanner/
│   ├── RuleScannerView.swift
│   ├── YARAParser.swift
│   ├── RuleCompiler.swift
│   ├── RuleMatcher.swift
│   └── RuleLibrary.swift
├── GadgetFinder/
│   ├── GadgetFinderView.swift
│   ├── ROPEngine.swift
│   ├── JOPEngine.swift
│   ├── GadgetChainBuilder.swift
│   └── ChainValidator.swift
├── DumpForensics/
│   ├── DumpForensicsView.swift
│   ├── MemoryDumpImporter.swift
│   ├── PointerScanner.swift
│   ├── ProcessCarver.swift
│   ├── ModuleExtractor.swift
│   └── KernelAnalyzer.swift
├── FirmwareAnalyzer/
│   ├── FirmwareAnalyzerView.swift
│   ├── UnblobBridge.swift
│   ├── PartitionExtractor.swift
│   ├── FilesystemAnalyzer.swift
│   └── BootloaderAnalyzer.swift
├── DeviceConsole/
│   ├── DeviceConsoleView.swift
│   ├── SerialConsole.swift
│   ├── GDBRSPClient.swift
│   ├── FlashDumpImporter.swift
│   └── JTAGInterface.swift
├── ScriptingConsole/
│   ├── ScriptingConsoleView.swift
│   ├── JavaScriptCoreBridge.swift
│   ├── AxiomAPI.swift
│   ├── ScriptLibrary.swift
│   └── REPLView.swift
├── ProjectStore/
│   ├── ProjectStoreView.swift
│   ├── ProjectManager.swift
│   ├── AnalysisStore.swift
│   ├── AnnotationManager.swift
│   ├── BookmarkManager.swift
│   ├── EditLog.swift
│   └── RevisionControl.swift
└── MCPTools/
    ├── MCPToolDefinitions.swift
    └── MCPToolHandlers.swift
```

---

## Binary Inspector

### File Import & Analysis

```swift
final class FileImporter: Sendable {
    func importFile(at url: URL) async throws -> BinaryAnalysis {
        // 1. Validate file
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as! Int
        guard size <= maxImportSize else { throw ImportError.fileTooLarge }
        
        // 2. Compute hashes
        let hashes = try await computeHashes(url)
        
        // 3. Detect architecture
        let architecture = try await ArchitectureDetector.detect(url)
        
        // 4. Identify format
        let format = try await FormatIdentifier.identify(url)
        
        // 5. Extract sections/segments
        let sections = try await SectionExtractor.extract(url, format: format)
        
        // 6. Create project
        let project = try await ProjectManager.create(
            fileURL: url,
            hashes: hashes,
            architecture: architecture,
            format: format,
            sections: sections
        )
        
        return BinaryAnalysis(
            project: project,
            hashes: hashes,
            architecture: architecture,
            format: format,
            sections: sections
        )
    }
}

struct BinaryAnalysis: Sendable {
    let project: AnalysisProject
    let hashes: FileHashes
    let architecture: Architecture
    let format: BinaryFormat
    let sections: [Section]
}

enum Architecture: String, Codable, Sendable {
    case x86, x86_64, arm, arm64, mips, ppc, sparc, unknown
}

enum BinaryFormat: String, Codable, Sendable {
    case macho, elf, pe, com, dos, unknown
}
```

### Universal Binary Handling

```swift
final class UniversalBinaryHandler: Sendable {
    func extractSlices(from url: URL) async throws -> [BinarySlice] {
        let fatHeader = try await readFatHeader(url)
        var slices: [BinarySlice] = []
        
        for arch in fatHeader.architectures {
            let sliceData = try await extractSlice(url, architecture: arch)
            let tempURL = try await writeToTempFile(sliceData)
            let analysis = try await FileImporter.shared.importFile(at: tempURL)
            slices.append(BinarySlice(architecture: arch, analysis: analysis))
        }
        
        return slices
    }
}

struct BinarySlice: Sendable {
    let architecture: Architecture
    let analysis: BinaryAnalysis
    let offset: UInt64
    let size: UInt64
}
```

---

## Disassembler & Decompiler

### Ghidra Headless Integration

```swift
final class GhidraHeadlessManager: Sendable {
    private let ghidraPath: URL
    private let projectDir: URL
    
    func analyze(
        binary: URL,
        projectName: String,
        options: GhidraAnalysisOptions
    ) async throws -> GhidraAnalysisResult {
        let args = [
            "analyzeHeadless",
            projectDir.path,
            projectName,
            "-import", binary.path,
            "-processor", options.processor,
            "-cspec", options.compilerSpec,
            "-analysis", options.analysisLevel.rawValue,
            "-postScript", options.postScript?.path ?? "",
            "-deleteProject"
        ]
        
        let process = ProcessRunner(
            executable: ghidraPath.appendingPathComponent("support/analyzeHeadless").path,
            arguments: args
        )
        
        return try await process.run { output in
            GhidraOutputParser.parse(output)
        }
    }
    
    func decompile(
        projectName: String,
        functionAddress: String,
        outputPath: URL
    ) async throws -> DecompilationResult {
        let args = [
            "analyzeHeadless",
            projectDir.path,
            projectName,
            "-process", functionAddress,
            "-scriptPath", scriptsDir.path,
            "-postScript", "DecompileFunction.java",
            outputPath.path,
            "-deleteProject"
        ]
        
        let process = ProcessRunner(
            executable: ghidraPath.appendingPathComponent("support/analyzeHeadless").path,
            arguments: args
        )
        
        return try await process.run { output in
            DecompilationOutputParser.parse(output)
        }
    }
}

struct GhidraAnalysisOptions: Sendable {
    let processor: String
    let compilerSpec: String
    let analysisLevel: AnalysisLevel
    let postScript: URL?
    
    enum AnalysisLevel: String, Sendable {
        case minimal = "minimal"
        case default_ = "default"
        case aggressive = "aggressive"
    }
}
```

### Radare2 Integration

```swift
final class Radare2Manager: Sendable {
    private let r2Path: URL
    
    func analyze(binary: URL, options: Radare2Options) async throws -> Radare2Project {
        let project = Radare2Project(binary: binary)
        
        // Open with flags
        let flags = [
            "-e", "cfg.bigendian=\(options.bigEndian ? "true" : "false")",
            "-e", "asm.arch=\(options.architecture.rawValue)",
            "-e", "asm.bits=\(options.bits)",
            "-e", "anal.all=\(options.analyzeAll ? "true" : "false")",
            "-e", "anal.functions=\(options.analyzeFunctions ? "true" : "false")"
        ]
        
        try await project.execute("aaa")  // Analyze all
        return project
    }
    
    func decompile(
        project: Radare2Project,
        functionAddress: String
    ) async throws -> String {
        try await project.execute("pdg @ \(functionAddress)")  // Ghidra-style decompilation
    }
    
    func disassemble(
        project: Radare2Project,
        address: String,
        count: Int
    ) async throws -> [Instruction] {
        let output = try await project.execute("pd \(count) @ \(address)")
        return InstructionParser.parse(output)
    }
}
```

### Unified Disassembly View

```swift
struct Instruction: Identifiable, Sendable {
    let id = UUID()
    let address: UInt64
    let bytes: Data
    let mnemonic: String
    let operands: [Operand]
    let comment: String?
    let references: [Reference]
    let flowType: FlowType
}

enum FlowType: String, Sendable {
    case sequential, branch, call, return, conditional, interrupt
}
```

---

## Function Analyzer

### Function List & Detail

```swift
@Model
final class FunctionRecord {
    @Attribute(.unique) var id: String  // "0x1000"
    var address: UInt64
    var name: String
    var demangledName: String?
    var size: UInt64
    var signature: String?
    var callingConvention: CallingConvention?
    var returnType: String?
    var parameters: [Parameter]
    var localVariables: [LocalVariable]
    var blocks: [BasicBlock]
    var callers: [UInt64]
    var callees: [UInt64]
    var references: [Reference]
    var strings: [StringReference]
    var comments: [Comment]
    var bookmarks: [Bookmark]
    var tags: [String]
    var analysisStatus: AnalysisStatus
    var pseudocode: String?
    var assembly: String?
}

enum AnalysisStatus: String, Codable, Sendable {
    case pending, analyzing, analyzed, failed, skipped
}
```

### Call Graph

```swift
final class CallGraphBuilder: Sendable {
    func buildCallGraph(
        from functions: [FunctionRecord],
        root: UInt64,
        direction: GraphDirection,
        maxDepth: Int
    ) async -> CallGraph {
        var visited: Set<UInt64> = []
        var edges: [CallEdge] = []
        
        func traverse(_ addr: UInt64, depth: Int) {
            guard depth < maxDepth, !visited.contains(addr) else { return }
            visited.insert(addr)
            
            let funcRecord = functions.first { $0.address == addr }
            let targets = direction == .forward ? funcRecord?.callees ?? [] : funcRecord?.callers ?? []
            
            for target in targets {
                edges.append(CallEdge(from: addr, to: target, type: .direct))
                traverse(target, depth: depth + 1)
            }
        }
        
        traverse(root, depth: 0)
        
        return CallGraph(nodes: visited.map { CallNode(address: $0) }, edges: edges)
    }
}

struct CallGraph: Sendable {
    let nodes: [CallNode]
    let edges: [CallEdge]
}
```

---

## Crypto Scanner

### Constant Detection

```swift
final class CryptoConstantScanner: Sendable {
    let detectors: [ConstantDetector] = [
        AESDetector(),
        SHADetector(),
        MD5Detector(),
        KeccakDetector(),
        BlowfishDetector(),
        ChaChaDetector(),
        CRC32Detector(),
        RSADetector()
    ]
    
    func scan(data: Data, options: ScanOptions) async -> [CryptoHit] {
        var hits: [CryptoHit] = []
        
        await withTaskGroup(of: [CryptoHit].self) { group in
            for detector in detectors {
                group.addTask {
                    await detector.detect(in: data, options: options)
                }
            }
            
            for await detectorHits in group {
                hits.append(contentsOf: detectorHits)
            }
        }
        
        return hits.sorted { $0.confidence > $1.confidence }
    }
}

protocol ConstantDetector: Sendable {
    var name: String { get }
    var patterns: [ConstantPattern] { get }
    func detect(in data: Data, options: ScanOptions) async -> [CryptoHit]
}

struct CryptoHit: Identifiable, Sendable {
    let id = UUID()
    let offset: UInt64
    let length: Int
    let algorithm: String
    let constantType: ConstantType
    let confidence: Double
    let evidence: Evidence
    let context: String
}

enum ConstantType: String, Sendable {
    case sbox, permutation, constant, keySchedule, roundConstant
    case modulus, exponent, prime, generator, curveParam
}
```

---

## Auto Decryptor

### Transform Pipeline

```swift
final class AutoDecryptor: Sendable {
    let transforms: [Transform] = [
        XORTransform(),
        AESTransform(),
        AESGCMTransform(),
        ChaCha20Poly1305Transform()
    ]
    
    func attemptDecryption(
        data: Data,
        options: DecryptOptions
    ) async -> [DecryptCandidate] {
        var candidates: [DecryptCandidate] = []
        
        // 1. Generate key candidates
        let keyCandidates = await generateKeyCandidates(data, options)
        
        // 2. Try each transform with each key
        await withTaskGroup(of: [DecryptCandidate].self) { group in
            for transform in transforms {
                for key in keyCandidates {
                    group.addTask {
                        await transform.tryDecrypt(data: data, key: key, options: options)
                    }
                }
            }
            
            for await transformCandidates in group {
                candidates.append(contentsOf: transformCandidates)
            }
        }
        
        // 3. Validate candidates
        let validated = await validateCandidates(candidates)
        
        // 4. Rank by structural evidence
        return rankCandidates(validated)
    }
}

protocol Transform: Sendable {
    var name: String { get }
    var supportedModes: [Mode] { get }
    func tryDecrypt(data: Data, key: KeyCandidate, options: DecryptOptions) async -> [DecryptCandidate]
}

struct DecryptCandidate: Identifiable, Sendable {
    let id = UUID()
    let transform: String
    let key: KeyCandidate
    let keyFingerprint: String  // SHA-256 of key
    let output: Data
    let validators: [ValidationResult]
    let confidence: Double
    let evidence: StructuralEvidence
}
```

### Key Generation

```swift
final class KeyGenerator: Sendable {
    func generateCandidates(
        from data: Data,
        options: DecryptOptions
    ) async -> [KeyCandidate] {
        var candidates: [KeyCandidate] = []
        
        // From file strings
        let strings = extractStrings(from: data)
        for string in strings {
            candidates.append(KeyCandidate(
                material: string.data(using: .utf8)!,
                source: .string(string)
            ))
        }
        
        // From wordlists
        if let wordlist = options.wordlist {
            for word in wordlist {
                candidates.append(KeyCandidate(
                    material: word.data(using: .utf8)!,
                    source: .wordlist
                ))
            }
        }
        
        // From entropy analysis
        let entropyRegions = EntropyAnalyzer.findHighEntropyRegions(data)
        for region in entropyRegions {
            candidates.append(KeyCandidate(
                material: data[region],
                source: .entropyRegion
            ))
        }
        
        // Derived keys (PBKDF2, HKDF, etc.)
        if options.enableKDF {
            candidates.append(contentsOf: await deriveKeys(from: data, candidates: candidates))
        }
        
        return candidates
    }
}
```

---

## Rule Scanner (YARA)

### YARA Rule Engine

```swift
final class YARAEngine: Sendable {
    private var compiler: YARACompiler
    private var rules: CompiledRules
    
    func compile(rulesSource: String) async throws -> CompiledRules {
        // Parse YARA syntax subset
        let parsed = try YARAParser.parse(rulesSource)
        
        // Validate syntax
        try validateRules(parsed)
        
        // Compile to bytecode
        let compiled = try compiler.compile(parsed)
        
        self.rules = compiled
        return compiled
    }
    
    func scan(data: Data) async -> [RuleMatch] {
        return await rules.match(data)
    }
}

struct YARARule: Sendable {
    let name: String
    let tags: [String]
    let meta: [String: String]
    let strings: [YARAString]
    let condition: YARACondition
}

enum YARAString: Sendable {
    case text(String, modifiers: [StringModifier])
    case hex(HexPattern)
    case regex(String, modifiers: [StringModifier])
}

enum StringModifier: String, Sendable {
    case nocase, wide, ascii, fullword
}
```

---

## Gadget Finder (ROP/JOP)

### ROP Chain Builder

```swift
final class ROPEngine: Sendable {
    func findGadgets(
        in binary: BinaryAnalysis,
        options: GadgetOptions
    ) async -> [Gadget] {
        let disassembly = await Disassembler.disassemble(binary)
        var gadgets: [Gadget] = []
        
        // Search for instruction sequences ending in target mnemonic
        for instruction in disassembly {
            if options.endingMnemonics.contains(instruction.mnemonic) {
                let chain = buildChain(
                    endingAt: instruction.address,
                    maxDepth: options.maxDepth,
                    disassembly: disassembly
                )
                
                if chain.instructions.count >= options.minLength {
                    gadgets.append(Gadget(
                        address: chain.startAddress,
                        instructions: chain.instructions,
                        effect: analyzeEffect(chain),
                        constraints: chain.constraints
                    ))
                }
            }
        }
        
        return gadgets
    }
    
    private func buildChain(
        endingAt address: UInt64,
        maxDepth: Int,
        disassembly: [Instruction]
    ) -> GadgetChain {
        // Backward slice from target instruction
    }
}

struct Gadget: Identifiable, Sendable {
    let id = UUID()
    let address: UInt64
    let instructions: [Instruction]
    let effect: RegisterEffect
    let constraints: [Constraint]
    let bytes: Data
}

struct RegisterEffect: Sendable {
    let registers: [String: RegisterValue]
    let memory: [UInt64: MemoryValue]
    let flags: FlagState
}
```

---

## Dump Forensics

### Memory Dump Analysis

```swift
final class MemoryDumpAnalyzer: Sendable {
    func analyze(dumpURL: URL) async throws -> DumpAnalysis {
        // 1. Identify dump format
        let format = try identifyFormat(dumpURL)
        
        // 2. Extract modules
        let modules = try await ModuleExtractor.extract(dumpURL, format: format)
        
        // 3. Scan for pointers
        let pointers = await PointerScanner.scan(dumpURL)
        
        // 4. Carve processes
        let processes = try await ProcessCarver.carve(dumpURL, pointers: pointers)
        
        return DumpAnalysis(
            format: format,
            modules: modules,
            pointers: pointers,
            processes: processes
        )
    }
}

struct DumpAnalysis: Sendable {
    let format: DumpFormat
    let modules: [LoadedModule]
    let pointers: [Pointer]
    let processes: [ProcessInfo]
}

enum DumpFormat: String, Sendable {
    case macho, elf, raw, windows, unknown
}
```

---

## Firmware Analyzer

### Unblob Integration

```swift
final class FirmwareAnalyzer: Sendable {
    private let unblobPath: URL
    
    func extract(
        firmwareURL: URL,
        outputDir: URL,
        options: ExtractOptions
    ) async throws -> FirmwareExtractionResult {
        let args = [
            "extract",
            firmwareURL.path,
            "-o", outputDir.path,
            "-d", String(options.maxDepth),
            "-s", String(options.maxSize)
        ]
        
        let process = ProcessRunner(
            executable: unblobPath.path,
            arguments: args
        )
        
        return try await process.run { output in
            FirmwareExtractionParser.parse(output)
        }
    }
    
    func analyzeExtracted(
        at directory: URL
    ) async -> FirmwareAnalysis {
        // Recursively analyze extracted components
    }
}
```

---

## Device Console

### Serial Console

```swift
final class SerialConsole: Sendable {
    private var port: SerialPort?
    
    func connect(
        to device: String,
        baudRate: Int,
        dataBits: Int,
        stopBits: Int,
        parity: Parity
    ) async throws {
        port = try SerialPort(path: device)
        try port?.configure(
            baudRate: baudRate,
            dataBits: dataBits,
            stopBits: stopBits,
            parity: parity
        )
        
        // Start reading
        Task {
            for await line in port!.lines {
                await handleLine(line)
            }
        }
    }
    
    func write(_ data: Data) async throws {
        try await port?.write(data)
    }
    
    func capture(to file: URL) async throws {
        // Log all traffic
    }
}
```

### GDB RSP Client

```swift
final class GDBRSPClient: Sendable {
    func connect(to target: String) async throws
    func attach(pid: Int) async throws
    func detach() async throws
    
    func readMemory(address: UInt64, length: Int) async throws -> Data
    func writeMemory(address: UInt64, data: Data) async throws
    func readRegisters() async throws -> [Register]
    func writeRegister(name: String, value: UInt64) async throws
    
    func setBreakpoint(address: UInt64, type: BreakpointType) async throws
    func removeBreakpoint(address: UInt64) async throws
    
    func continueExecution() async throws
    func step() async throws
    func stepOver() async throws
}
```

---

## Scripting Console

### JavaScriptCore with Axiom API

```swift
final class ScriptingConsole: Sendable {
    private let context: JSContext
    
    func initialize() {
        context = JSContext()
        context.exceptionHandler = { context, exception in
            print("JS Exception: \(exception?.toString() ?? "unknown")")
        }
        
        // Expose Axiom API
        exposeAxiomAPI()
    }
    
    private func exposeAxiomAPI() {
        let axiom = JSValue(newObjectIn: context)
        
        // Binary operations
        axiom.setObject(unsafeBitCast({ (path: String) -> JSValue in
            return self.jsImportBinary(path)
        }, to: @convention(block) (String) -> JSValue.self), forKeyedSubscript: "importBinary")
        
        axiom.setObject(unsafeBitCast({ (address: String) -> JSValue in
            return self.jsAnalyzeFunction(address)
        }, to: @convention(block) (String) -> JSValue.self), forKeyedSubscript: "analyzeFunction")
        
        axiom.setObject(unsafeBitCast({ (address: String) -> JSValue in
            return self.jsGetDisassembly(address)
        }, to: @convention(block) (String) -> JSValue.self), forKeyedSubscript: "getDisassembly")
        
        axiom.setObject(unsafeBitCast({ (address: String) -> JSValue in
            return self.jsGetDecompilation(address)
        }, to: @convention(block) (String) -> JSValue.self), forKeyedSubscript: "getDecompilation")
        
        axiom.setObject(unsafeBitCast({ (address: String) -> JSValue in
            return self.jsGetXrefs(address)
        }, to: @convention(block) (String) -> JSValue.self), forKeyedSubscript: "getXrefs")
        
        axiom.setObject(unsafeBitCast({ (pattern: String) -> JSValue in
            return self.jsSearchStrings(pattern)
        }, to: @convention(block) (String) -> JSValue.self), forKeyedSubscript: "searchStrings")
        
        context.setObject(axiom, forKeyedSubscript: "axiom")
    }
    
    func evaluate(_ script: String) -> JSValue {
        return context.evaluateScript(script)
    }
}
```

---

## Project Store

### Analysis Persistence

```swift
@Model
final class AnalysisProject {
    @Attribute(.unique) var id: UUID
    var name: String
    var fileURL: URL
    var fileHashes: FileHashes
    var architecture: Architecture
    var format: BinaryFormat
    var createdAt: Date
    var updatedAt: Date
    var functions: [FunctionRecord]
    var strings: [StringRecord]
    var annotations: [Annotation]
    var bookmarks: [Bookmark]
    var editLog: [EditEntry]
    var revision: Int
}

struct Annotation: Codable, Sendable {
    let id: UUID
    let address: UInt64
    let type: AnnotationType
    let content: String
    let author: String
    let timestamp: Date
    let revision: Int
}

enum AnnotationType: String, Codable, Sendable {
    case comment, label, bookmark, warning, note
}
```

### Atomic Saves with Revision Control

```swift
final class ProjectStore: Sendable {
    func save(_ project: AnalysisProject) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(project)
        
        // Atomic write with revision check
        let tempURL = project.fileURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        
        // Verify
        let savedData = try Data(contentsOf: tempURL)
        let decoded = try JSONDecoder().decode(AnalysisProject.self, from: savedData)
        guard decoded.revision == project.revision else {
            throw ProjectStoreError.revisionMismatch
        }
        
        // Replace
        try FileManager.default.replaceItemAt(
            project.fileURL,
            withItemAt: tempURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }
}
```

---

## MCP Tool Integration

### Tool Definitions

```swift
let reTools: [MCPTool] = [
    MCPTool(
        name: "import_binary",
        description: "Import a binary for analysis",
        inputSchema: .object([
            "path": .string,
            "format": .string.optional
        ])
    ),
    MCPTool(
        name: "analyze_function",
        description: "Analyze a function by address or name",
        inputSchema: .object([
            "project_id": .string,
            "address": .string.optional,
            "name": .string.optional
        ])
    ),
    MCPTool(
        name: "get_disassembly",
        description: "Get disassembly for a function",
        inputSchema: .object([
            "project_id": .string,
            "address": .string
        ])
    ),
    MCPTool(
        name: "get_decompilation",
        description: "Get decompilation for a function",
        inputSchema: .object([
            "project_id": .string,
            "address": .string
        ])
    ),
    MCPTool(
        name: "search_strings",
        description: "Search strings in binary",
        inputSchema: .object([
            "project_id": .string,
            "pattern": .string,
            "case_sensitive": .boolean.optional
        ])
    ),
    MCPTool(
        name: "get_xrefs",
        description: "Get cross-references to/from an address",
        inputSchema: .object([
            "project_id": .string,
            "address": .string,
            "direction": .string.optional  // "to" | "from"
        ])
    ),
    MCPTool(
        name: "scan_crypto",
        description: "Scan for crypto constants",
        inputSchema: .object([
            "project_id": .string
        ])
    ),
    MCPTool(
        name: "auto_decrypt",
        description: "Attempt automatic decryption",
        inputSchema: .object([
            "project_id": .string,
            "ciphers": .array.optional,
            "keys": .array.optional,
            "wordlist": .string.optional
        ])
    ),
    MCPTool(
        name: "find_gadgets",
        description: "Find ROP/JOP gadgets",
        inputSchema: .object([
            "project_id": .string,
            "ending": .string.optional,
            "depth": .integer.optional
        ])
    ),
    MCPTool(
        name: "carve_formats",
        description: "Carve embedded file formats",
        inputSchema: .object([
            "project_id": .string
        ])
    )
]
```

---

## Integration with SuperMetaApp

### Cross-Module Workflows

```
┌─────────────────┐     ┌─────────────────┐
│  ReverseEng     │────▶│  AgenticConsole │
│  (Analyze Bin)  │     │  (Explain/Report)│
└─────────────────┘     └─────────────────┘
        │                       │
        ▼                       ▼
┌─────────────────────────────────────────┐
│           Shared Workspace               │
│  • Binary Files    • Analysis Projects   │
│  • Annotations     • Decompilations      │
└─────────────────────────────────────────┘
        │
        ▼
┌─────────────────┐     ┌─────────────────┐
│  DevPlatform    │────▶│  ModelLab       │
│  (Patch/Build)  │     │  (Extract/ML)   │
└─────────────────┘     └─────────────────┘
```

### Shared Services Used

| Service | Usage |
|---------|-------|
| ModelRegistry | AI-assisted analysis, function naming, decompilation improvement |
| MCPClient | External analysis tools, custom scripts |
| WorkspaceManager | Binary files, project storage |
| TerminalService | Ghidra/radare2 process management |
| GitService | Version control for analysis projects |
| SettingsService | Engine paths, analysis preferences |
| KeychainService | License keys, API tokens |

---

## Performance Targets

| Operation | Target |
|-----------|--------|
| Binary Import (10 MB) | < 5s |
| Ghidra Analysis (medium) | < 60s |
| Function Decompilation | < 3s |
| String Search (1M strings) | < 1s |
| Crypto Scan | < 10s |
| Auto Decrypt (small) | < 30s |
| Memory (large project) | < 2 GB |

---

## Legal & Ethical Guardrails

- **No Execution** — Never executes analyzed binaries
- **Static Only** — All analysis is static; no dynamic analysis without explicit user consent
- **Authorized Only** — Tools only work on files user has rights to analyze
- **No Exploit Generation** — Gadget finder reports findings only; no chain construction
- **Audit Trail** — All analysis actions logged with timestamps
- **Export Control** — Sensitive findings require explicit export action

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review