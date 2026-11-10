import Foundation

/// Minimal PNG chunk reader and writer, enough to embed generation settings as text chunks and read them back.
/// ImageIO cannot write arbitrary text keywords, and the file must stay a normal PNG that any viewer opens.
public enum PNGChunks {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public struct Chunk: Equatable, Sendable {
        public var type: String
        public var data: Data
    }

    public static func isPNG(_ data: Data) -> Bool { data.count >= 8 && Array(data.prefix(8)) == signature }

    /// Chunks in file order. Returns nil when the bytes are not a PNG or a chunk runs past the end.
    public static func parse(_ data: Data) -> [Chunk]? {
        guard isPNG(data) else { return nil }
        let bytes = [UInt8](data)
        var chunks: [Chunk] = []
        var i = 8
        while i + 12 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            let end = i + 8 + length
            guard length >= 0, end + 4 <= bytes.count else { return nil }
            chunks.append(Chunk(type: type, data: Data(bytes[(i + 8)..<end])))
            i = end + 4
            if type == "IEND" { break }
        }
        return chunks
    }

    public static func serialize(_ chunks: [Chunk]) -> Data {
        var out = Data(signature)
        for chunk in chunks {
            var length = UInt32(chunk.data.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            let typeBytes = Data(chunk.type.utf8)
            out.append(typeBytes)
            out.append(chunk.data)
            var crc = crc32(typeBytes + chunk.data).bigEndian
            out.append(Data(bytes: &crc, count: 4))
        }
        return out
    }

    /// Adds (or replaces, by keyword) UTF-8 text chunks just before the image data. Returns the input unchanged if it is not a PNG.
    public static func embedText(_ entries: [(keyword: String, text: String)], in png: Data) -> Data {
        guard var chunks = parse(png) else { return png }
        let keywords = Set(entries.map(\.keyword))
        chunks.removeAll { chunk in
            guard ["tEXt", "iTXt"].contains(chunk.type), let entry = decodeText(chunk) else { return false }
            return keywords.contains(entry.keyword)
        }
        let firstData = chunks.firstIndex { $0.type == "IDAT" } ?? max(1, chunks.count - 1)
        let added = entries.map { entry -> Chunk in
            // International text: keyword, NUL, compression flag 0, method 0, empty language tag, NUL, empty translated keyword, NUL, text.
            var payload = Data(String(entry.keyword.prefix(79)).utf8)
            payload.append(contentsOf: [0, 0, 0, 0, 0])
            payload.append(Data(entry.text.utf8))
            return Chunk(type: "iTXt", data: payload)
        }
        chunks.insert(contentsOf: added, at: firstData)
        return serialize(chunks)
    }

    /// Every text chunk as keyword and text. Compressed text is skipped.
    public static func textEntries(in png: Data) -> [(keyword: String, text: String)] {
        (parse(png) ?? []).compactMap(decodeText)
    }

    public static func text(forKeyword keyword: String, in png: Data) -> String? {
        textEntries(in: png).first { $0.keyword == keyword }?.text
    }

    static func decodeText(_ chunk: Chunk) -> (keyword: String, text: String)? {
        let bytes = [UInt8](chunk.data)
        guard let nul = bytes.firstIndex(of: 0) else { return nil }
        let keyword = String(decoding: bytes[..<nul], as: UTF8.self)
        switch chunk.type {
        case "tEXt":
            return (keyword, String(decoding: bytes[(nul + 1)...], as: UTF8.self))
        case "iTXt":
            guard nul + 2 < bytes.count, bytes[nul + 1] == 0 else { return nil }   // compressed: not supported
            var i = nul + 3
            guard let langEnd = bytes[i...].firstIndex(of: 0) else { return nil }
            i = langEnd + 1
            guard let transEnd = bytes[i...].firstIndex(of: 0) else { return nil }
            return (keyword, String(decoding: bytes[(transEnd + 1)...], as: UTF8.self))
        default:
            return nil
        }
    }

    // MARK: CRC-32 (PNG polynomial)

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// What gets written into each picture: the whole request plus what the engine actually used.
public struct GenerationRecord: Codable, Equatable, Sendable {
    public var request: ImageGenerationRequest
    public var engine: String
    public var modelName: String
    /// The seed that produced this picture (the request's seed is nil when it was random).
    public var seed: Int64
    public var seconds: Double
    public var createdAt: Date
    public var kilnVersion: String

    public init(request: ImageGenerationRequest, engine: String, modelName: String, seed: Int64, seconds: Double,
                createdAt: Date = Date(), kilnVersion: String = "1") {
        self.request = request; self.engine = engine; self.modelName = modelName; self.seed = seed
        self.seconds = seconds; self.createdAt = createdAt; self.kilnVersion = kilnVersion
    }

    /// A request that reproduces this picture: same settings, the seed pinned, one image.
    public var rerunRequest: ImageGenerationRequest {
        var again = request
        again.seed = seed
        again.count = 1
        again.engine = engine
        return again
    }
}

public enum GenerationMetadata {
    public static let kilnKeyword = "kiln-generation"
    public static let parametersKeyword = "parameters"

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Embeds the record as JSON (`kiln-generation`) and as the Automatic1111-style `parameters` text other tools read.
    public static func embed(_ record: GenerationRecord, in png: Data) -> Data {
        var entries: [(keyword: String, text: String)] = []
        if let json = try? encoder().encode(record), let text = String(data: json, encoding: .utf8) {
            entries.append((kilnKeyword, text))
        }
        entries.append((parametersKeyword, a1111Text(record)))
        return PNGChunks.embedText(entries, in: png)
    }

    public static func read(from png: Data) -> GenerationRecord? {
        guard let text = PNGChunks.text(forKeyword: kilnKeyword, in: png), let data = text.data(using: .utf8) else { return nil }
        return try? decoder().decode(GenerationRecord.self, from: data)
    }

    static func a1111Text(_ record: GenerationRecord) -> String {
        let r = record.request
        var lines = [r.prompt]
        if !r.negativePrompt.isEmpty { lines.append("Negative prompt: \(r.negativePrompt)") }
        var parts = ["Steps: \(r.steps)"]
        if let sampler = r.sampler { parts.append("Sampler: \(sampler)") }
        parts.append("CFG scale: \(r.guidance)")
        parts.append("Seed: \(record.seed)")
        parts.append("Size: \(r.width)x\(r.height)")
        parts.append("Model: \(record.modelName)")
        if r.task != .textToImage { parts.append("Denoising strength: \(r.strength)") }
        if !r.loras.isEmpty { parts.append("Lora hashes: " + r.loras.map { "\($0.name): \($0.weight)" }.joined(separator: ", ")) }
        parts.append("Version: Kiln Image studio (\(record.engine))")
        lines.append(parts.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}
