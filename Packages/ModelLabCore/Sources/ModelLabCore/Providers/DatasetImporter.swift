import Foundation
import TabularData

public struct DatasetPreview: Sendable {
    public let format: DatasetFileFormat
    public let columns: [String]
    public let sampleRows: [[String]]
    public let rowCount: Int?
}

public struct DatasetTable: Sendable {
    public let format: DatasetFileFormat
    public let columns: [String]
    public let rows: [[String: String]]
}

/// Imports a local file/folder or a downloaded dataset file into a real,
/// inspectable preview: detected columns, a handful of sample rows, and a
/// row count where it's cheap to compute one. Supports the formats called
/// out in the requirements: CSV, JSONL, TXT, and an images folder (treated
/// as an unlabeled/foldered image classification layout).
public struct DatasetImporter: Sendable {
    public init() {}

    public func detectFormat(at url: URL) -> DatasetFileFormat {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .imagesFolder
        }
        switch url.pathExtension.lowercased() {
        case "csv", "tsv": return .csv
        case "jsonl", "ndjson": return .jsonl
        case "json": return .json
        case "txt": return .txt
        default: return .unknown
        }
    }

    public func preview(at url: URL, maxRows: Int = 20) throws -> DatasetPreview {
        let format = detectFormat(at: url)
        switch format {
        case .csv:
            let table = try table(at: url)
            let rows = table.rows.prefix(maxRows).map { row in
                table.columns.map { row[$0] ?? "" }
            }
            return DatasetPreview(format: format, columns: table.columns, sampleRows: Array(rows), rowCount: table.rows.count)

        case .jsonl:
            return try previewJSONLines(at: url, maxRows: maxRows)

        case .json:
            return try previewJSON(at: url, maxRows: maxRows)

        case .txt:
            let lines = try readLines(url: url)
            let rows = lines.prefix(maxRows).map { [$0] }
            return DatasetPreview(format: format, columns: ["text"], sampleRows: Array(rows), rowCount: lines.count)

        case .imagesFolder:
            let fm = FileManager.default
            let subfolders = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []
            let labels = subfolders.map(\.lastPathComponent).sorted()
            var counts: [[String]] = []
            for folder in subfolders.prefix(maxRows) {
                let count = (try? fm.contentsOfDirectory(atPath: folder.path).count) ?? 0
                counts.append([folder.lastPathComponent, "\(count) files"])
            }
            return DatasetPreview(format: format, columns: ["label", "fileCount"], sampleRows: counts, rowCount: labels.count)

        case .unknown:
            throw DatasetProviderError.unsupportedFileType(url.pathExtension)
        }
    }

    public func table(at url: URL) throws -> DatasetTable {
        let format = detectFormat(at: url)
        switch format {
        case .csv:
            let dataFrame = try DataFrame(contentsOfCSVFile: url)
            let columns = dataFrame.columns.map(\.name)
            let rows = dataFrame.rows.map { row in
                Dictionary(uniqueKeysWithValues: columns.map { name in
                    (name, row[name].map { "\($0)" } ?? "")
                })
            }
            return DatasetTable(format: format, columns: columns, rows: rows)
        case .jsonl:
            let objects = try jsonLineObjects(at: url)
            return makeJSONTable(objects: objects, format: .jsonl)
        case .json:
            let objects = try jsonObjects(at: url)
            return makeJSONTable(objects: objects, format: .json)
        case .txt:
            let rows = try readLines(url: url).map { ["text": $0] }
            return DatasetTable(format: format, columns: ["text"], rows: rows)
        case .imagesFolder, .unknown:
            throw DatasetProviderError.unsupportedFileType(url.pathExtension)
        }
    }

    private func previewJSONLines(at url: URL, maxRows: Int) throws -> DatasetPreview {
        try makeJSONPreview(objects: jsonLineObjects(at: url), format: .jsonl, maxRows: maxRows)
    }

    private func previewJSON(at url: URL, maxRows: Int) throws -> DatasetPreview {
        try makeJSONPreview(objects: jsonObjects(at: url), format: .json, maxRows: maxRows)
    }

    private func jsonLineObjects(at url: URL) throws -> [[String: Any]] {
        let lines = try readLines(url: url).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { throw DatasetProviderError.emptyFile }
        return try lines.map { line in
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DatasetProviderError.unsupportedFileType("jsonl (not a JSON object per line)")
            }
            return object
        }
    }

    private func jsonObjects(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !value.isEmpty else {
            throw DatasetProviderError.unsupportedFileType("json (expected an array of objects)")
        }
        return value
    }

    private func makeJSONPreview(objects: [[String: Any]], format: DatasetFileFormat, maxRows: Int) -> DatasetPreview {
        let columns = Set(objects.flatMap(\.keys)).sorted()
        let rows = objects.prefix(maxRows).map { object in
            columns.map { key in stringify(object[key]) }
        }
        return DatasetPreview(format: format, columns: columns, sampleRows: Array(rows), rowCount: objects.count)
    }

    private func stringify(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(value)"
    }

    private func makeJSONTable(objects: [[String: Any]], format: DatasetFileFormat) -> DatasetTable {
        let columns = Set(objects.flatMap(\.keys)).sorted()
        let rows = objects.map { object in
            Dictionary(uniqueKeysWithValues: columns.map { key in
                (key, stringify(object[key]))
            })
        }
        return DatasetTable(format: format, columns: columns, rows: rows)
    }

    private func readLines(url: URL) throws -> [String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
