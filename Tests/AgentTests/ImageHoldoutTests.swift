import Foundation
import Testing
@testable import Kiln

@Suite("Held-out image sets")
struct ImageHoldoutTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("holdout-\(UUID().uuidString)")
        for (label, names) in [("cat", ["a.jpg", "b.png"]), ("dog", ["c.jpeg", "notes.txt"])] {
            let dir = root.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names { try Data([0]).write(to: dir.appendingPathComponent(name)) }
        }
        return root
    }

    @Test("subfolder names become true labels and non-images are skipped") func labels() throws {
        let items = try ImageHoldout.collect(imagePaths: nil, folder: try makeTree().path)
        #expect(items.map(\.trueLabel) == ["cat", "cat", "dog"])
        #expect(items.map { $0.url.lastPathComponent } == ["a.jpg", "b.png", "c.jpeg"])
    }
    @Test("the report scores against folder names and flags misses") func report() throws {
        let items = try ImageHoldout.collect(imagePaths: nil, folder: try makeTree().path)
        let text = ImageHoldout.report(images: items, results: [("cat", 0.9), ("dog", 0.6), nil])
        #expect(text.contains("a.jpg → cat (0.90)"))
        #expect(text.contains("b.png → dog (0.60) [expected cat]"))
        #expect(text.contains("Accuracy against folder names: 1/2 = 50.0%"))
        #expect(text.contains("1 image(s) could not be classified"))
    }
    @Test("bad input is refused") func refused() {
        #expect(throws: (any Error).self) { try ImageHoldout.collect(imagePaths: nil, folder: nil) }
        #expect(throws: (any Error).self) { try ImageHoldout.collect(imagePaths: ["relative.png"], folder: nil) }
        #expect(throws: (any Error).self) { try ImageHoldout.collect(imagePaths: nil, folder: "/definitely/not/here") }
    }
    @Test("the tool is read-only and registered") func registered() {
        #expect(ModelLabAgentTools.Kind.predictImages.spec.permission == .read)
        #expect(ModelLabAgentTools.Kind.predictImages.spec.name == "lab_predict_images")
    }
}
