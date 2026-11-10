import Foundation
import AxiomCore

/// What is inside an IPA or APK, read from the archive without running anything. File extraction goes through the same
/// bounded ZIP reader the rest of Kiln uses.
public struct REPackageReport: Sendable, Equatable {
    public enum Kind: String, Sendable { case ipa, apk, unknown }
    public struct File: Sendable, Equatable, Identifiable { public var id: String { name }; public let name: String; public let size: Int }
    public var kind: Kind
    public var appName: String?
    public var identifier: String?
    public var version: String?
    public var minimumOS: String?
    /// Path of the main executable inside the archive (IPA) or the DEX/primary library (APK).
    public var executable: String?
    /// Info.plist keys (IPA) or manifest attributes (APK), flattened to strings.
    public var properties: [(key: String, value: String)] = []
    public var entitlements: [(key: String, value: String)] = []
    public var permissions: [String] = []
    public var components: [(kind: String, name: String)] = []
    public var classes: [String] = []
    public var methodCount = 0
    public var resources: [String] = []
    public var libraries: [String] = []
    public var files: [File] = []
    public var warnings: [String] = []

    public static func == (a: REPackageReport, b: REPackageReport) -> Bool {
        a.kind == b.kind && a.identifier == b.identifier && a.version == b.version && a.files == b.files && a.classes == b.classes
    }

    public func json() -> [String: Any] {
        ["kind": kind.rawValue, "name": appName as Any? ?? NSNull(), "identifier": identifier as Any? ?? NSNull(), "version": version as Any? ?? NSNull(),
         "minimum_os": minimumOS as Any? ?? NSNull(), "executable": executable as Any? ?? NSNull(),
         "properties": properties.map { ["key": $0.key, "value": $0.value] }, "entitlements": entitlements.map { ["key": $0.key, "value": $0.value] },
         "permissions": permissions, "components": components.map { ["kind": $0.kind, "name": $0.name] },
         "class_count": classes.count, "classes": Array(classes.prefix(500)), "method_count": methodCount,
         "resources": Array(resources.prefix(500)), "libraries": libraries, "file_count": files.count, "warnings": warnings]
    }
}

public enum REPackage {
    public static let maxArchiveBytes = 512 * 1024 * 1024

    public static func inspect(_ url: URL) throws -> REPackageReport {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? Int ?? 0) <= maxArchiveBytes else { throw REError.invalidArgument("package is larger than 512 MiB") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try ZipReader.entries(data)
        var report = REPackageReport(kind: .unknown)
        report.files = entries.filter { !$0.name.hasSuffix("/") }.map { .init(name: $0.name, size: $0.uncompressedSize) }
        if entries.contains(where: { $0.name == "AndroidManifest.xml" }) { try inspectAPK(data, entries, &report) }
        else if entries.contains(where: { $0.name.hasPrefix("Payload/") && $0.name.hasSuffix(".app/Info.plist") }) { try inspectIPA(data, entries, &report) }
        else { report.warnings.append("This archive is neither an IPA (no Payload/*.app) nor an APK (no AndroidManifest.xml).") }
        return report
    }

    /// Extracts one archive entry into a new folder and returns its URL, ready for `importBinary`.
    public static func extract(_ archive: URL, entry name: String, into folder: URL) throws -> URL {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try ZipReader.entries(data)
        guard let entry = ZipReader.entry(named: name, in: entries) else { throw REError.invalidArgument("\(name) is not in the archive") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never trust the entry path: only its last component is used.
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        guard !leaf.isEmpty, leaf != "..", leaf != "." else { throw REError.invalidArgument("unsafe entry name") }
        let output = folder.appendingPathComponent(leaf)
        try ZipReader.extract(data, entry: entry).write(to: output)
        return output
    }

    // MARK: IPA

    private static func inspectIPA(_ data: Data, _ entries: [ZipEntry], _ report: inout REPackageReport) throws {
        report.kind = .ipa
        guard let plistEntry = entries.first(where: { $0.name.hasPrefix("Payload/") && $0.name.hasSuffix(".app/Info.plist") && $0.name.split(separator: "/").count == 3 }) else {
            report.warnings.append("No top-level app Info.plist."); return
        }
        let appFolder = String(plistEntry.name.dropLast("Info.plist".count))
        let plist = try PropertyListSerialization.propertyList(from: ZipReader.extract(data, entry: plistEntry), format: nil) as? [String: Any] ?? [:]
        report.properties = plist.keys.sorted().map { ($0, describe(plist[$0])) }
        report.appName = (plist["CFBundleDisplayName"] ?? plist["CFBundleName"]) as? String
        report.identifier = plist["CFBundleIdentifier"] as? String
        report.version = [plist["CFBundleShortVersionString"], plist["CFBundleVersion"]].compactMap { $0 as? String }.joined(separator: " (") + (plist["CFBundleVersion"] == nil || plist["CFBundleShortVersionString"] == nil ? "" : ")")
        report.minimumOS = plist["MinimumOSVersion"] as? String
        if let executable = plist["CFBundleExecutable"] as? String { report.executable = appFolder + executable }
        report.libraries = entries.filter { $0.name.hasPrefix(appFolder + "Frameworks/") && $0.name.hasSuffix(".framework/") }.map { $0.name.replacingOccurrences(of: appFolder, with: "") }
        if report.libraries.isEmpty {
            report.libraries = Array(Set(entries.compactMap { entry -> String? in
                guard entry.name.hasPrefix(appFolder + "Frameworks/") else { return nil }
                return entry.name.dropFirst((appFolder + "Frameworks/").count).split(separator: "/").first.map(String.init)
            })).sorted()
        }
        report.resources = entries.filter { $0.name.hasPrefix(appFolder) && !$0.name.hasSuffix("/") && !$0.name.hasPrefix(appFolder + "Frameworks/") && !$0.name.contains("_CodeSignature") }
            .map { $0.name.replacingOccurrences(of: appFolder, with: "") }.sorted()
        // Entitlements: the provisioning profile carries a plist; the binary's signature carries another.
        if let profile = entries.first(where: { $0.name == appFolder + "embedded.mobileprovision" }), let bytes = try? ZipReader.extract(data, entry: profile),
           let dictionary = embeddedPlist(bytes), let entitlements = dictionary["Entitlements"] as? [String: Any] {
            report.entitlements = entitlements.keys.sorted().map { ($0, describe(entitlements[$0])) }
        }
        if report.entitlements.isEmpty, let executable = report.executable, let entry = ZipReader.entry(named: executable, in: entries),
           entry.uncompressedSize <= 200 * 1024 * 1024, let bytes = try? ZipReader.extract(data, entry: entry), let dictionary = embeddedPlist(bytes, containing: "entitlements") ?? embeddedPlist(bytes, containing: "application-identifier") {
            report.entitlements = dictionary.keys.sorted().map { ($0, describe(dictionary[$0])) }
        }
        if report.entitlements.isEmpty { report.warnings.append("No entitlements found: the app may be unsigned or the profile was stripped.") }
        // Class names from the Mach-O's Objective-C metadata are listed after import (the ObjC and Swift names appear as functions).
        if let executable = report.executable, let entry = ZipReader.entry(named: executable, in: entries), entry.uncompressedSize <= 200 * 1024 * 1024,
           let bytes = try? ZipReader.extract(data, entry: entry) {
            report.classes = objcClassNames(bytes)
        }
    }

    /// Finds the first XML plist embedded in binary data (a CMS-wrapped provisioning profile or a code-signature entitlements blob).
    static func embeddedPlist(_ data: Data, containing marker: String? = nil) -> [String: Any]? {
        let open = Data("<?xml".utf8), close = Data("</plist>".utf8)
        var from = data.startIndex
        while let start = data.range(of: open, in: from..<data.endIndex), let end = data.range(of: close, in: start.lowerBound..<data.endIndex) {
            let slice = data[start.lowerBound..<end.upperBound]
            if marker == nil || String(decoding: slice, as: UTF8.self).contains(marker!),
               let object = try? PropertyListSerialization.propertyList(from: slice, format: nil) as? [String: Any] { return object }
            from = end.upperBound
        }
        return nil
    }

    /// Objective-C class names that appear as `_OBJC_CLASS_$_Name` symbols or `OBJC_CLASS_$_` strings.
    static func objcClassNames(_ data: Data) -> [String] {
        let marker = Data("_OBJC_CLASS_$_".utf8)
        var names = Set<String>()
        var from = data.startIndex
        while let range = data.range(of: marker, in: from..<data.endIndex), names.count < 5000 {
            var end = range.upperBound
            while end < data.endIndex, data[end] != 0, data[end] >= 33, data[end] < 127, end - range.upperBound < 200 { end += 1 }
            if end > range.upperBound { names.insert(String(decoding: data[range.upperBound..<end], as: UTF8.self)) }
            from = max(end, range.upperBound)
        }
        return names.sorted()
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let array as [Any]: return array.map { describe($0) }.joined(separator: ", ")
        case let dictionary as [String: Any]: return dictionary.keys.sorted().map { "\($0)=\(describe(dictionary[$0]))" }.joined(separator: "; ")
        case let data as Data: return "<\(data.count) bytes>"
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let bool as Bool: return bool ? "true" : "false"
        case let other?: return "\(other)"
        case nil: return ""
        }
    }

    // MARK: APK

    private static func inspectAPK(_ data: Data, _ entries: [ZipEntry], _ report: inout REPackageReport) throws {
        report.kind = .apk
        if let manifest = ZipReader.entry(named: "AndroidManifest.xml", in: entries) {
            let events = try AndroidXML.parse(ZipReader.extract(data, entry: manifest))
            var currentComponent: String?
            for event in events {
                guard case let .startElement(name, _, attributes) = event else { continue }
                func value(_ key: String) -> String? { attributes.first { $0.name == key }?.value }
                switch name {
                case "manifest":
                    report.identifier = value("package"); report.version = value("versionName")
                    for attribute in attributes { report.properties.append((attribute.name, attribute.value)) }
                case "uses-sdk": report.minimumOS = value("minSdkVersion").map { "API " + $0 }
                case "uses-permission", "uses-permission-sdk-23": if let permission = value("name") { report.permissions.append(permission) }
                case "application": report.appName = value("label"); for attribute in attributes { report.properties.append(("application." + attribute.name, attribute.value)) }
                case "activity", "activity-alias", "service", "receiver", "provider":
                    currentComponent = value("name")
                    if let componentName = currentComponent {
                        report.components.append((name + (value("exported") == "true" ? " (exported)" : ""), componentName))
                    }
                default: break
                }
            }
            _ = currentComponent
        }
        var methods = 0
        for entry in entries where entry.name.hasPrefix("classes") && entry.name.hasSuffix(".dex") {
            guard entry.uncompressedSize <= 128 * 1024 * 1024 else { report.warnings.append("\(entry.name) skipped: larger than 128 MiB"); continue }
            do {
                let listing = try DexFile.parse(ZipReader.extract(data, entry: entry))
                report.classes += listing.classes.map(\.name)
                methods += listing.methods.count
            } catch { report.warnings.append("\(entry.name): \(error.localizedDescription)") }
        }
        report.methodCount = methods
        report.classes = Array(report.classes.prefix(50_000))
        report.libraries = entries.filter { $0.name.hasPrefix("lib/") && $0.name.hasSuffix(".so") }.map(\.name)
        report.resources = entries.filter { $0.name.hasPrefix("res/") || $0.name.hasPrefix("assets/") || $0.name == "resources.arsc" }.map(\.name).sorted()
        if let table = ZipReader.entry(named: "resources.arsc", in: entries), table.uncompressedSize <= 64 * 1024 * 1024,
           let parsed = try? AndroidResources.parse(ZipReader.extract(data, entry: table)) {
            let count = parsed.reduce(0) { $0 + $1.entries.count }
            report.properties.append(("resources.arsc entries", String(count)))
            if let label = parsed.flatMap(\.entries).first(where: { $0.key == "app_name" }) { report.properties.append(("resource app_name id", String(format: "0x%08x", label.id))) }
        }
        report.executable = entries.first { $0.name.hasPrefix("lib/arm64-v8a/") && $0.name.hasSuffix(".so") }?.name ?? entries.first { $0.name == "classes.dex" }?.name
    }
}
