import Testing
import Foundation
import SwiftData
import ModelLabCore
@testable import SuperMetaApp

@Suite struct ModelExporterTests {
    @Test func coreMLExportCopiesRealFile() throws {
        let dir = makeTempDirectory("coreml-export")
        let source = dir.appendingPathComponent("model.mlmodel")
        try Data([0xAA, 0xBB]).write(to: source)
        let (record, context) = makeRecord(format: .mlmodel, relativePath: "model.mlmodel", in: dir)

        let exporters = ModelExporters()
        #expect(exporters.coreMLCapability(for: record, absoluteURL: source).isAvailable)
        let destination = makeTempDirectory("coreml-destination")
        let exported = try exporters.export(record: record, absoluteURL: source, format: .coreML, to: destination)
        #expect(FileManager.default.fileExists(atPath: exported.path))
        #expect(exported.lastPathComponent == "model.mlmodel")
    }

    @Test func coreMLExportRefusesNonCoreMLArtifacts() throws {
        let (record, _) = makeRecord(format: .mlxFolder, relativePath: "mymodel", in: makeTempDirectory("x"))
        let status = ModelExporters().coreMLCapability(for: record, absoluteURL: nil)
        #expect(!status.isAvailable)
        #expect(status.reason?.contains("coremltools") == true)
    }

    @Test func coreMLExportRefusesMissingSource() throws {
        let dir = makeTempDirectory("missing-src")
        let (record, _) = makeRecord(format: .mlmodel, relativePath: "ghost.mlmodel", in: dir)
        #expect(!ModelExporters().coreMLCapability(for: record, absoluteURL: dir.appendingPathComponent("ghost.mlmodel")).isAvailable)
    }

    @Test func mlxPackageExportBundlesManifest() throws {
        let dir = makeTempDirectory("mlxpkg-src")
        let source = dir.appendingPathComponent("scratch-lm", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([0x01]).write(to: source.appendingPathComponent("weights.safetensors"))
        let (record, _) = makeRecord(format: .mlxScratchModel, relativePath: "scratch-lm", in: dir)

        let destination = makeTempDirectory("mlxpkg-destination")
        let exported = try ModelExporters().export(record: record, absoluteURL: source, format: .mlxPackage, to: destination)
        let manifestURL = exported.appendingPathComponent("modellab-package.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(MLXPackageManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.artifactFormat == ModelFormat.mlxScratchModel.rawValue)
        #expect(manifest.sourceModule == "com.supermeta.modellab")
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("weights.safetensors").path))
    }

    @Test func exportNeverOverwrites() throws {
        let dir = makeTempDirectory("no-overwrite")
        let source = dir.appendingPathComponent("model.mlmodel")
        try Data([1]).write(to: source)
        let (record, _) = makeRecord(format: .mlmodel, relativePath: "model.mlmodel", in: dir)
        let destination = makeTempDirectory("no-overwrite-dst")
        try Data([2]).write(to: destination.appendingPathComponent("model.mlmodel"))

        let exported = try ModelExporters().export(record: record, absoluteURL: source, format: .coreML, to: destination)
        #expect(exported.lastPathComponent == "model-1.mlmodel")
        // The pre-existing file is untouched.
        #expect(try Data(contentsOf: destination.appendingPathComponent("model.mlmodel")) == Data([2]))
    }

    @Test func ggufReportsSpecificUnavailability() {
        let status = ModelExporters.ggufCapability()
        #expect(!status.isAvailable)
        // The reason must name the actual missing tool — never a generic one.
        #expect(status.reason?.contains("llama.cpp") == true)
    }

    @Test func exportThrowForGGUFNamesReason() throws {
        let dir = makeTempDirectory("gguf-throw")
        let (record, _) = makeRecord(format: .mlxFolder, relativePath: "m", in: dir)
        #expect(throws: ModelExporters.ExportError.self) {
            _ = try ModelExporters().export(
                record: record,
                absoluteURL: dir.appendingPathComponent("m"),
                format: .gguf,
                to: makeTempDirectory("gguf-dst")
            )
        }
    }

    // MARK: Fixtures

    private func makeTempDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sma-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecord(format: ModelFormat, relativePath: String, in libraryRoot: URL) -> (ModelArtifactRecord, ModelContext) {
        let configuration = ModelConfiguration(schema: Schema([ModelArtifactRecord.self]), isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Schema([ModelArtifactRecord.self]), configurations: [configuration])
        let context = ModelContext(container)
        let record = ModelArtifactRecord(
            name: "Test \(format.rawValue)",
            format: format,
            origin: .trainedLocally,
            localRelativePath: relativePath,
            sizeBytes: 8,
            sourceIdentifier: nil,
            task: nil,
            experimentID: "exp-1",
            notes: "test artifact"
        )
        context.insert(record)
        return (record, context)
    }
}

@Suite struct ModelLabManifestTests {
    @Test func manifestCapabilitiesParseToKnownBits() {
        let (known, unknown) = ModuleCapabilities.parse([
            "fileSystem.readWrite", "network.client", "metal.compute", "neuralEngine",
        ])
        #expect(unknown.isEmpty)
        #expect(known.contains(.fileSystemRead))
        #expect(known.contains(.fileSystemWrite))
        #expect(known.contains(.networkClient))
        #expect(known.contains(.metalCompute))
        #expect(known.contains(.neuralEngine))
    }

    @Test func moduleRequiredCapabilitiesMatchManifest() {
        let declared = ModuleCapabilities.parse([
            "fileSystem.readWrite", "network.client", "metal.compute", "neuralEngine",
        ]).known
        #expect(ModelLabModule.requiredCapabilities.isSuperset(of: declared))
        #expect(declared.isSuperset(of: ModelLabModule.requiredCapabilities))
    }
}
