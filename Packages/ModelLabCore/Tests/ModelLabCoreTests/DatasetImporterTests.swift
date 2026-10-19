import Foundation
import Testing
@testable import ModelLabCore

struct DatasetImporterTests {
    @Test func detectsCSVFormat() throws {
        let importer = DatasetImporter()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try "text,label\nhello world,greeting\ngoodbye,farewell\n".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(importer.detectFormat(at: tempURL) == .csv)
        let preview = try importer.preview(at: tempURL)
        #expect(preview.columns == ["text", "label"])
        #expect(preview.sampleRows.count == 2)
        #expect(preview.rowCount == 2)
    }

    @Test func detectsJSONLFormat() throws {
        let importer = DatasetImporter()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let content = #"{"text":"hi","label":"a"}"# + "\n" + #"{"text":"bye","label":"b"}"# + "\n"
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(importer.detectFormat(at: tempURL) == .jsonl)
        let preview = try importer.preview(at: tempURL)
        #expect(Set(preview.columns) == Set(["text", "label"]))
        #expect(preview.sampleRows.count == 2)
    }

    @Test func previewsJSONArrayAndUnionsColumns() throws {
        let importer = DatasetImporter()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let content = #"[{"text":"hello","label":"positive"},{"text":"bye","label":"negative","score":0.1}]"#
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(importer.detectFormat(at: tempURL) == .json)
        let preview = try importer.preview(at: tempURL)
        #expect(preview.columns == ["label", "score", "text"])
        #expect(preview.sampleRows.count == 2)
        #expect(preview.rowCount == 2)
        #expect(preview.sampleRows[0] == ["positive", "", "hello"])
    }

    @Test func loadsJSONLAsNamedRowsForEvaluation() throws {
        let importer = DatasetImporter()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let content = #"{"text":"hi","label":"a"}"# + "\n" + #"{"text":"bye","label":"b","score":1}"# + "\n"
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let table = try importer.table(at: tempURL)
        #expect(table.columns == ["label", "score", "text"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0]["text"] == "hi")
        #expect(table.rows[1]["score"] == "1")
    }

    @Test func detectsImagesFolder() throws {
        let importer = DatasetImporter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cats"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dogs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(importer.detectFormat(at: root) == .imagesFolder)
        let preview = try importer.preview(at: root)
        #expect(preview.rowCount == 2)
    }
}
