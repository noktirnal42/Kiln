import Foundation

// Dump forensics (docs/KALI_METASPLOIT_PARITY.md T10, Volatility-inspired): raw memory/flash dumps
// have no container format, so modules are found by scanning for known executable-format headers
// at any offset (reusing FormatIdentifier) and walking each one's own structure to compute its real
// on-disk extent — never a blind, unbounded "to end of file" guess. macOS and embedded Linux first
// (Mach-O, ELF); Volatility's Windows profile system is a later, data-driven add per the parity doc.
// Pointer scanning is a plain heuristic (aligned values inside a plausible address range), offered
// as investigative leads, never as a claim that a value is actually a pointer.

public struct DumpModule: Codable, Sendable, Equatable {
    public let offset: Int
    public let format: String
    /// Computed on-disk size when the header could be walked; nil when only the signature matched
    /// (truncated dump, or a format this parser doesn't walk, e.g. a bare Universal/Java 0xcafebabe hit).
    public let size: Int?
    public let note: String?
}

public enum DumpForensics {
    static let maxModules = 2048
    static let maxExtractBytes = 256 * 1024 * 1024   // matches the app-wide import cap

    /// Finds every embedded Mach-O/ELF header and computes its real extent by walking load commands
    /// (Mach-O) or the section header table (ELF), so a module can be sliced out exactly.
    public static func listModules(_ data: Data) -> [DumpModule] {
        var modules: [DumpModule] = []
        for hit in FormatIdentifier.scan(data) where modules.count < maxModules {
            switch hit.format {
            case "Mach-O 64-bit", "Mach-O 32-bit":
                modules.append(DumpModule(offset: hit.offset, format: hit.format, size: machOSize(data, at: hit.offset), note: hit.note))
            case "ELF":
                modules.append(DumpModule(offset: hit.offset, format: hit.format, size: elfSize(data, at: hit.offset), note: hit.note))
            default: continue
            }
        }
        return modules
    }

    /// Slices exactly `size` bytes at `offset`, bounded by the file and a hard cap. Use a `size`
    /// from `listModules` (or your own analysis) rather than guessing.
    public static func extractModule(_ data: Data, offset: Int, size: Int) throws -> Data {
        guard offset >= 0, size > 0, offset + size <= data.count else { throw AxiomError.message("Requested range is outside the dump.") }
        guard size <= maxExtractBytes else { throw AxiomError.message("Extraction exceeds the \(maxExtractBytes / 1024 / 1024) MiB cap.") }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + size))
    }

    // MARK: Mach-O extent

    private static func u32(_ data: Data, _ offset: Int, big: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4))
        let value = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        return big ? value.bigEndian : value.littleEndian
    }
    private static func u64(_ data: Data, _ offset: Int, big: Bool) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        let bytes = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 8))
        let value = bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        return big ? value.bigEndian : value.littleEndian
    }

    /// Walks LC_SEGMENT(_64) commands and returns the highest `fileoff + filesize`, which is the
    /// standard way to size a Mach-O that has no outer container telling you where it ends.
    static func machOSize(_ data: Data, at offset: Int) -> Int? {
        // Magic encodes both word size and byte order: 0xfeedface/0xfeedfacf are stored big-endian
        // (so this machine's little-endian read of them lands on these exact big values); the
        // 0xce/0xcf-first forms are stored little-endian.
        // A native little-endian host load (this platform is always LE) yields the MH_MAGIC(_64)
        // value exactly when the file's own byte order matches the host (so its other fields need
        // no swapping); MH_CIGAM(_64) means the file is the opposite order and fields must be swapped.
        guard let magic = u32(data, offset, big: false) else { return nil }
        let is64: Bool, bigEndian: Bool
        switch magic {
        case 0xfeedfacf: is64 = true; bigEndian = false
        case 0xcffaedfe: is64 = true; bigEndian = true
        case 0xfeedface: is64 = false; bigEndian = false
        case 0xcefaedfe: is64 = false; bigEndian = true
        default: return nil
        }
        guard let commandCount = u32(data, offset + 16, big: bigEndian) else { return nil }
        let headerSize = is64 ? 32 : 28
        var cursor = offset + headerSize
        var maxExtent = headerSize
        let segmentCmd: UInt32 = is64 ? 0x19 : 0x1
        for _ in 0..<min(commandCount, 100_000) {
            guard let cmd = u32(data, cursor, big: bigEndian), let cmdsize = u32(data, cursor + 4, big: bigEndian), cmdsize >= 8 else { break }
            if cmd == segmentCmd {
                let fileoffOffset = cursor + 8 + 16 + (is64 ? 16 : 8)   // cmd+cmdsize+segname+vmaddr+vmsize
                let fileoff: UInt64?, filesize: UInt64?
                if is64 { fileoff = u64(data, fileoffOffset, big: bigEndian); filesize = u64(data, fileoffOffset + 8, big: bigEndian) }
                else { fileoff = u32(data, fileoffOffset, big: bigEndian).map(UInt64.init); filesize = u32(data, fileoffOffset + 4, big: bigEndian).map(UInt64.init) }
                if let fileoff, let filesize, fileoff < UInt64(Int.max), filesize < UInt64(Int.max) {
                    maxExtent = max(maxExtent, Int(fileoff) + Int(filesize))
                }
            }
            cursor += Int(cmdsize)
        }
        return maxExtent
    }

    // MARK: ELF extent

    /// Uses the section-header table's own offset/count/size, which (per the ELF spec's usual
    /// layout) sits after every section's data, so its end is the file's end.
    static func elfSize(_ data: Data, at offset: Int) -> Int? {
        guard offset + 20 <= data.count, data[data.startIndex + offset] == 0x7f, data[data.startIndex + offset + 1] == 0x45,
              data[data.startIndex + offset + 2] == 0x4c, data[data.startIndex + offset + 3] == 0x46 else { return nil }
        let is64 = data[data.startIndex + offset + 4] == 2
        let bigEndian = data[data.startIndex + offset + 5] == 2
        let ehsize = is64 ? 64 : 52
        let shoffOffset = offset + (is64 ? 40 : 32)
        let shentsizeOffset = offset + (is64 ? 58 : 46)
        let shnumOffset = shentsizeOffset + 2
        guard let shoff64 = is64 ? u64(data, shoffOffset, big: bigEndian) : u32(data, shoffOffset, big: bigEndian).map(UInt64.init) else { return nil }
        guard let shentsizeU32 = u16(data, shentsizeOffset, big: bigEndian), let shnumU32 = u16(data, shnumOffset, big: bigEndian) else { return nil }
        let tableEnd = Int(shoff64) + Int(shentsizeU32) * Int(shnumU32)
        return max(ehsize, tableEnd)
    }
    private static func u16(_ data: Data, _ offset: Int, big: Bool) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let bytes = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 2))
        let value = bytes.withUnsafeBytes { $0.load(as: UInt16.self) }
        return big ? value.bigEndian : value.littleEndian
    }

    // MARK: Core-dump containers

    public struct CoreRegion: Codable, Sendable, Equatable {
        public let virtualAddress: UInt64
        public let memorySize: UInt64
        public let fileOffset: Int
        public let fileSize: Int
        /// Raw permission/flag bits as recorded by the container (ELF p_flags, Mach-O initprot).
        public let flags: UInt32
        /// True when the region's file bytes extend past the end of the supplied data.
        public let truncated: Bool
    }
    public struct CoreDump: Codable, Sendable, Equatable {
        public let format: String
        public let regions: [CoreRegion]
        /// True when the region list hit `maxCoreRegions` and was cut short.
        public let regionListTruncated: Bool
    }
    static let maxCoreRegions = 100_000

    /// Reads the memory-region table of an ELF core (ET_CORE) or Mach-O core (MH_CORE) file. Returns
    /// nil for anything else, including ordinary executables. Regions are what the container itself
    /// declares; nothing is inferred about what they hold (heap vs. stack vs. mapped image).
    public static func parseCore(_ data: Data) -> CoreDump? {
        if let elf = parseElfCore(data) { return elf }
        return parseMachOCore(data)
    }

    private static func parseElfCore(_ data: Data) -> CoreDump? {
        guard data.count >= 52, data[data.startIndex] == 0x7f, data[data.startIndex + 1] == 0x45, data[data.startIndex + 2] == 0x4c, data[data.startIndex + 3] == 0x46 else { return nil }
        let is64 = data[data.startIndex + 4] == 2, big = data[data.startIndex + 5] == 2
        guard u16(data, 16, big: big) == 4 else { return nil }   // ET_CORE
        let phoff: UInt64?, phentsize: UInt16?, phnum: UInt16?
        if is64 { phoff = u64(data, 32, big: big); phentsize = u16(data, 54, big: big); phnum = u16(data, 56, big: big) }
        else { phoff = u32(data, 28, big: big).map(UInt64.init); phentsize = u16(data, 42, big: big); phnum = u16(data, 44, big: big) }
        guard let phoff, let phentsize, let phnum, phentsize >= (is64 ? 56 : 32), phoff <= UInt64(data.count) else { return nil }
        var regions: [CoreRegion] = []
        var cut = false
        for index in 0..<Int(phnum) {
            let base = Int(phoff) + index * Int(phentsize)
            guard base + Int(phentsize) <= data.count, let type = u32(data, base, big: big) else { break }
            guard type == 1 else { continue }   // PT_LOAD
            if regions.count >= maxCoreRegions { cut = true; break }
            let off: UInt64?, vaddr: UInt64?, filesz: UInt64?, memsz: UInt64?, flags: UInt32?
            if is64 {
                flags = u32(data, base + 4, big: big); off = u64(data, base + 8, big: big); vaddr = u64(data, base + 16, big: big)
                filesz = u64(data, base + 32, big: big); memsz = u64(data, base + 40, big: big)
            } else {
                off = u32(data, base + 4, big: big).map(UInt64.init); vaddr = u32(data, base + 8, big: big).map(UInt64.init)
                filesz = u32(data, base + 16, big: big).map(UInt64.init); memsz = u32(data, base + 20, big: big).map(UInt64.init); flags = u32(data, base + 24, big: big)
            }
            guard let off, let vaddr, let filesz, let memsz, let flags, off <= UInt64(Int.max), filesz <= UInt64(Int.max) else { continue }
            regions.append(CoreRegion(virtualAddress: vaddr, memorySize: memsz, fileOffset: Int(off), fileSize: Int(filesz), flags: flags, truncated: off + filesz > UInt64(data.count)))
        }
        return CoreDump(format: is64 ? "ELF64 core" : "ELF32 core", regions: regions, regionListTruncated: cut)
    }

    private static func parseMachOCore(_ data: Data) -> CoreDump? {
        guard data.count >= 32, u32(data, 0, big: false) == 0xfeedfacf, u32(data, 12, big: false) == 4 else { return nil }   // 64-bit little-endian MH_CORE
        guard let ncmds = u32(data, 16, big: false), let sizeofcmds = u32(data, 20, big: false) else { return nil }
        let end = min(data.count, 32 + Int(sizeofcmds))
        var cursor = 32
        var regions: [CoreRegion] = []
        var cut = false
        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= end, let cmd = u32(data, cursor, big: false), let size = u32(data, cursor + 4, big: false), size >= 8, cursor + Int(size) <= end else { break }
            if cmd == 0x19, size >= 72 {   // LC_SEGMENT_64
                if regions.count >= maxCoreRegions { cut = true; break }
                if let vmaddr = u64(data, cursor + 24, big: false), let vmsize = u64(data, cursor + 32, big: false), let fileoff = u64(data, cursor + 40, big: false),
                   let filesize = u64(data, cursor + 48, big: false), let initprot = u32(data, cursor + 60, big: false), fileoff <= UInt64(Int.max), filesize <= UInt64(Int.max) {
                    regions.append(CoreRegion(virtualAddress: vmaddr, memorySize: vmsize, fileOffset: Int(fileoff), fileSize: Int(filesize), flags: initprot, truncated: fileoff + filesize > UInt64(data.count)))
                }
            }
            cursor += Int(size)
        }
        return CoreDump(format: "Mach-O 64 core", regions: regions, regionListTruncated: cut)
    }

    // MARK: Pointer heuristic

    /// Default plausible user-space pointer range for arm64 macOS/iOS. A heuristic starting point,
    /// not a guarantee — pass your own range for other platforms/ABIs.
    public static let arm64UserSpaceRange: ClosedRange<UInt64> = 0x100000000...0x7fffffffe000

    /// Offsets of every `alignment`-aligned 8-byte little-endian value inside `range`. These are
    /// candidate pointers for the analyst to follow up on, nothing more.
    public static func scanPointers(_ data: Data, range: ClosedRange<UInt64> = arm64UserSpaceRange, alignment: Int = 8, limit: Int = 10_000) -> [Int] {
        guard alignment > 0, data.count >= 8 else { return [] }
        var hits: [Int] = []
        var offset = 0
        let last = data.count - 8
        while offset <= last, hits.count < limit {
            if let value = u64(data, offset, big: false), range.contains(value) { hits.append(offset) }
            offset += alignment
        }
        return hits
    }
}
