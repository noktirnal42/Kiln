import Foundation

/// A universal (fat) Mach-O holds one image per architecture. Engines analyze one image at a time, so the chosen
/// slice is extracted to a temporary thin file that keeps the original file name; the project still records the
/// original file's path and SHA-256 plus which slice was analyzed.
public struct SliceResolution {
    /// File the engines should read: the original when it is not universal, otherwise the extracted slice.
    public let path: String
    /// Architectures in a universal binary, empty when the file is not universal.
    public let slices: [String]
    public let chosen: String?
    private let directory: String?
    init(path: String, slices: [String], chosen: String?, directory: String?) { self.path = path; self.slices = slices; self.chosen = chosen; self.directory = directory }
    public func cleanup() { if let directory { try? FileManager.default.removeItem(atPath: directory) } }
}

extension Analyzer {
    static let lipo = "/usr/bin/lipo"

    /// Host architecture first, so analysis matches what would run natively; otherwise the first slice.
    public static func preferredSlice(_ slices: [String]) -> String? {
        #if arch(arm64)
        let host = "arm64"
        #else
        let host = "x86_64"
        #endif
        return slices.contains(host) ? host : slices.first
    }

    static func isFatMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        return [[0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf]].contains(Array(head))
    }

    public static func resolveSlice(_ path: String, arch: String? = nil) throws -> SliceResolution {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // 0xcafebabe is also the Java class magic, so lipo has the final say on whether this is a universal binary.
        guard isFatMagic(url), let listing = try? ProcessRunner.run(lipo, ["-archs", url.path]) else {
            if let arch { throw AxiomError.message("\(url.lastPathComponent) is not a universal binary, so arch \"\(arch)\" cannot be selected.") }
            return SliceResolution(path: url.path, slices: [], chosen: nil, directory: nil)
        }
        let slices = listing.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard slices.count > 1 || arch != nil, !slices.isEmpty else { return SliceResolution(path: url.path, slices: slices, chosen: slices.first, directory: nil) }
        let chosen = arch ?? preferredSlice(slices)!
        guard slices.contains(chosen) else { throw AxiomError.message("Architecture \"\(chosen)\" is not in this universal binary. Available: \(slices.joined(separator: ", ")).") }
        let directory = NSTemporaryDirectory() + "axiom-slice-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let thin = directory + "/" + url.lastPathComponent
        do { _ = try ProcessRunner.run(lipo, [url.path, "-thin", chosen, "-output", thin]) }
        catch { try? FileManager.default.removeItem(atPath: directory); throw error }
        return SliceResolution(path: thin, slices: slices, chosen: chosen, directory: directory)
    }
}
