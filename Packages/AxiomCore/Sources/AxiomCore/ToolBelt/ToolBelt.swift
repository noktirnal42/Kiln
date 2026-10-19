import Foundation

// Tool belt entry points (docs/KALI_METASPLOIT_PARITY.md): bounded file loading for the scanning
// modules, matching the app-wide import limits so CLI, MCP and app surfaces share one contract.

public enum ToolBelt {
    /// Scan cap mirrors the app import limit (docs/SPEC.md).
    public static let scanLimit = 256 * 1024 * 1024
    /// Wordlist cap matches the catalog download cap.
    public static let wordlistLimit = 64 * 1024 * 1024

    public static func readData(_ path: String, limit: Int = scanLimit) throws -> Data {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw AxiomError.message("Choose a regular file.") }
        guard let size = attrs[.size] as? Int, size <= limit else {
            throw AxiomError.message("File exceeds the \(limit / 1024 / 1024) MiB scan limit.")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
