import Foundation
import Testing
@testable import Kiln

private func fakeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-drive-home-\(UUID().uuidString)")
    let fm = FileManager.default
    let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    try fm.createDirectory(at: icloud.appendingPathComponent("Papers"), withIntermediateDirectories: true)
    try "# Notes\nhello".write(to: icloud.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    try "paper text".write(to: icloud.appendingPathComponent("Papers/analysis.txt"), atomically: true, encoding: .utf8)
    try Data([0, 1, 2, 3, 0]).write(to: icloud.appendingPathComponent("blob.bin"))
    try "x".write(to: icloud.appendingPathComponent(".report.pdf.icloud"), atomically: true, encoding: .utf8)   // an online-only placeholder
    try "secret outside the drive".write(to: home.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(at: icloud.appendingPathComponent("escape"), withDestinationURL: home.appendingPathComponent("outside.txt"))
    try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/GoogleDrive-ada@example.com/My Drive"), withIntermediateDirectories: true)
    try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/Dropbox"), withIntermediateDirectories: true)
    try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/Mystery-Vault"), withIntermediateDirectories: true)
    return home
}

@Suite("Cloud drives")
struct DriveServiceTests {
    private func service(_ home: URL) -> DriveService { DriveService(home: home, isCloudOnly: { $0.lastPathComponent == "cloud.txt" || DriveService.systemIsCloudOnly($0) }) }

    @Test func foldersSyncedByProviderAppsAreFoundAndNamed() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let found = service(home).locations()
        #expect(found.map(\.name) == ["iCloud Drive", "Dropbox", "Google Drive (ada@example.com)", "Mystery-Vault"])
        #expect(found.map(\.kind) == [.icloud, .dropbox, .googleDrive, .other])
        #expect(try service(home).location(named: "dropbox").name == "Dropbox")
        #expect(try service(home).location(named: "google").kind == .googleDrive)            // a unique partial name is enough
        #expect(throws: DriveError.noSuchLocation("onedrive")) { _ = try service(home).location(named: "onedrive") }
        #expect(DriveService.classify("OneDrive-Personal") == (.oneDrive, "OneDrive (Personal)") && DriveService.classify("Box-Box") == (.box, "Box (Box)"))
        #expect(DriveService(home: FileManager.default.temporaryDirectory.appendingPathComponent("nohome-\(UUID().uuidString)")).locations().isEmpty)
    }

    @Test func listingShowsFoldersFirstAndOnlineOnlyPlaceholdersUnderTheirRealNames() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let s = service(home), icloud = try s.location(named: "iCloud Drive")
        let top = try s.list(icloud)
        #expect(top.first?.name == "Papers" && top.first?.isDirectory == true)
        let report = try #require(top.first { $0.name == "report.pdf" })
        #expect(report.availability == .cloudOnly)
        #expect(top.first { $0.name == "notes.md" }?.availability == .local && !top.contains { $0.name.hasPrefix(".") })
        #expect(try s.list(icloud, path: "Papers").map(\.path) == ["Papers/analysis.txt"])
        #expect(throws: DriveError.notADirectory) { _ = try s.list(icloud, path: "notes.md") }
        #expect(throws: DriveError.self) { _ = try s.list(icloud, path: "Nope") }
    }

    @Test func nothingEscapesTheDrive() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let s = service(home), icloud = try s.location(named: "iCloud Drive")
        for bad in ["../outside.txt", "Papers/../../outside.txt", "escape", "/../outside.txt"] {
            #expect(throws: DriveError.outsideLocation, "\(bad)") { _ = try s.readText(icloud, path: bad) }
        }
        #expect(throws: DriveError.outsideLocation) { _ = try s.list(icloud, path: "..") }
        #expect(throws: DriveError.outsideLocation) { _ = try s.copyIn(home.appendingPathComponent("outside.txt"), to: icloud, path: "../stolen.txt") }
    }

    @Test func textReadsAreBoundedAndRefuseBinaryAndOnlineOnlyFiles() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let s = service(home), icloud = try s.location(named: "iCloud Drive")
        #expect(try s.readText(icloud, path: "notes.md") == "# Notes\nhello")
        #expect(throws: DriveError.binary) { _ = try s.readText(icloud, path: "blob.bin") }
        #expect(throws: DriveError.cloudOnly("report.pdf")) { _ = try s.readText(icloud, path: "report.pdf") }
        #expect(throws: DriveError.notAFile) { _ = try s.readText(icloud, path: "Papers") }
        let big = icloud.root.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: Int(DriveService.textLimit) + 10).write(to: big)
        #expect(throws: DriveError.self) { _ = try s.readText(icloud, path: "big.txt") }
        try "x".write(to: icloud.root.appendingPathComponent("cloud.txt"), atomically: true, encoding: .utf8)
        #expect(throws: DriveError.cloudOnly("cloud.txt")) { _ = try s.readText(icloud, path: "cloud.txt") }
    }

    @Test func searchMatchesNamesAndStopsOnHugeDrives() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let s = service(home), icloud = try s.location(named: "iCloud Drive")
        #expect(try s.search(icloud, query: "ANALYSIS").matches.map(\.path) == ["Papers/analysis.txt"])
        #expect(try s.search(icloud, query: "papers analysis").matches.isEmpty)           // every word must be in the same name
        #expect(try s.search(icloud, query: "  ").matches.isEmpty)
        let capped = try s.search(icloud, query: "n", limit: 1)
        #expect(capped.matches.count == 1 && capped.truncated)
        #expect(try s.search(icloud, query: "notes", maxVisited: 1).truncated)
    }

    @Test func copiesNeverOverwriteAndStayWhereTheyAreAimed() throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let s = service(home), icloud = try s.location(named: "iCloud Drive")
        let project = home.appendingPathComponent("project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let out = project.appendingPathComponent("notes.md")
        try s.copyOut(icloud, path: "notes.md", to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "# Notes\nhello")
        #expect(throws: DriveError.exists("notes.md")) { _ = try s.copyOut(icloud, path: "notes.md", to: out) }
        #expect(throws: DriveError.cloudOnly("report.pdf")) { _ = try s.copyOut(icloud, path: "report.pdf", to: project.appendingPathComponent("r.pdf")) }
        let made = try s.copyIn(out, to: icloud, path: "Uploads/notes-copy.md")
        #expect(made.path == "Uploads/notes-copy.md" && made.size > 0)
        #expect(throws: DriveError.exists("notes-copy.md")) { _ = try s.copyIn(out, to: icloud, path: "Uploads/notes-copy.md") }
    }
}

@Suite("Drive tools")
struct DriveToolTests {
    @Test func toolsLabelUntrustedTextAndConfineCopiesToTheProject() async throws {
        let home = try fakeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let service = DriveService(home: home)
        let project = home.appendingPathComponent("project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "local file".write(to: project.appendingPathComponent("up.txt"), atomically: true, encoding: .utf8)
        let ctx = ToolExecutionContext(workspaceRoot: project, conversationID: UUID())
        func run(_ k: DriveTool.Kind, _ json: String) async throws -> String { try await DriveTool(kind: k, service: service).execute(argumentsJSON: json, context: ctx) }
        #expect(try await run(.locations, "{}").contains("iCloud Drive | icloud"))
        let listing = try await run(.list, #"{"location":"icloud"}"#)
        #expect(listing.hasPrefix(DriveTool.untrusted) && listing.contains("file | notes.md") && listing.contains("online-only"))
        #expect(try await run(.read, #"{"location":"iCloud Drive","path":"notes.md"}"#).hasSuffix("hello"))
        #expect(try await run(.search, #"{"location":"icloud","query":"analysis"}"#).contains("Papers/analysis.txt"))
        #expect(try await run(.copyToProject, #"{"location":"icloud","path":"notes.md","destination":"got/notes.md"}"#).contains("Copied"))
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("got/notes.md").path))
        #expect(try await run(.save, #"{"location":"icloud","source":"up.txt","path":"Backup/up.txt"}"#).contains("will upload"))
        for (kind, json) in [(DriveTool.Kind.copyToProject, #"{"location":"icloud","path":"notes.md","destination":"../escape.md"}"#),
                             (.copyToProject, #"{"location":"icloud","path":"notes.md","destination":"got/notes.md"}"#),
                             (.save, #"{"location":"icloud","source":"../outside.txt","path":"x.txt"}"#),
                             (.save, #"{"location":"icloud","source":"up.txt","path":"Backup/up.txt"}"#),
                             (.read, #"{"location":"icloud","path":"../outside.txt"}"#), (.read, #"{"location":"nowhere","path":"a"}"#)] {
            await #expect(throws: (any Error).self, "\(json)") { _ = try await run(kind, json) }
        }
        let noRoot = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())
        await #expect(throws: (any Error).self) { _ = try await DriveTool(kind: .save, service: service).execute(argumentsJSON: #"{"location":"icloud","source":"up.txt","path":"z.txt"}"#, context: noRoot) }
    }

    @Test func tiers() {
        let s = DriveService(home: FileManager.default.temporaryDirectory)
        let t = Dictionary(uniqueKeysWithValues: DriveTool.Kind.allCases.map { ($0.rawValue, DriveTool(kind: $0, service: s).spec.permission) })
        #expect(t["drive_locations"] == .read && t["drive_list"] == .read && t["drive_search"] == .read && t["drive_read"] == .read)
        #expect(t["drive_copy_to_project"] == .write && t["drive_save"] == .admin)
    }
}
