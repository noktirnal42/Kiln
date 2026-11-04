import Foundation

/// Gathers a held-out set of images for `lab_predict_images` and reports on the predictions. Pure file listing and
/// formatting, so it is tested without a trained model.
enum ImageHoldout {
    struct Item: Equatable { let url: URL; let trueLabel: String? }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "tif", "bmp", "gif"]
    static let limit = 200

    static func collect(imagePaths: [String]?, folder: String?) throws -> [Item] {
        if let imagePaths, !imagePaths.isEmpty {
            guard imagePaths.count <= limit else { throw ModelLabToolError.invalid("image_paths holds at most \(limit) files") }
            return try imagePaths.map { path in
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { throw ModelLabToolError.invalid("\(path) is not an existing absolute path") }
                return Item(url: URL(fileURLWithPath: path), trueLabel: nil)
            }
        }
        guard let folder, folder.hasPrefix("/") else { throw ModelLabToolError.invalid("give image_paths or the absolute path of a folder of images") }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelLabToolError.invalid("folder must be an existing directory")
        }
        func images(in directory: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { imageExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        }
        var items = images(in: root).map { Item(url: $0, trueLabel: nil) }
        let subfolders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.path < $1.path }
        for sub in subfolders { items += images(in: sub).map { Item(url: $0, trueLabel: sub.lastPathComponent) } }
        guard !items.isEmpty else { throw ModelLabToolError.invalid("no images found in that folder") }
        guard items.count <= limit else { throw ModelLabToolError.invalid("that folder holds \(items.count) images; the limit is \(limit). Point at a smaller held-out set") }
        return items
    }

    static func report(images: [Item], results: [(label: String, confidence: Double)?]) -> String {
        var lines: [String] = []
        var scored = 0, correct = 0, unreadable = 0
        for (item, result) in zip(images, results) {
            guard let result else { unreadable += 1; lines.append("\(item.url.lastPathComponent) → could not be classified"); continue }
            var line = String(format: "%@ → %@ (%.2f)", item.url.lastPathComponent, result.label, result.confidence)
            if let truth = item.trueLabel {
                scored += 1
                if truth == result.label { correct += 1 } else { line += " [expected \(truth)]" }
            }
            lines.append(line)
        }
        if scored > 0 { lines.append(String(format: "Accuracy against folder names: %d/%d = %.1f%%", correct, scored, Double(correct) / Double(scored) * 100)) }
        if unreadable > 0 { lines.append("\(unreadable) image(s) could not be classified and are not counted.") }
        return lines.joined(separator: "\n")
    }
}
