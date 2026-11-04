import CoreGraphics
import Foundation
import ImageIO
import ModelLabCore
import Testing
@testable import Kiln

/// Real Create ML training on this Mac, then the agent tool's held-out path (`lab_predict_images`) over images the
/// model never saw. Opt-in: `TEST_RUNNER_KILN_LIVE=1`. The images are synthetic solid colours: this proves the pipeline
/// (train, load, classify, score against folder names), not model quality.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE"] == "1"), .serialized)
struct LiveImageClassifierTests {
    @MainActor @Test func aTrainedImageClassifierScoresAHeldOutFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let train = root.appendingPathComponent("train"), held = root.appendingPathComponent("held")
        for (label, rgb) in [("red", (200, 30, 30)), ("blue", (30, 30, 200))] {
            for (dir, count, jitter) in [(train, 10, 0), (held, 4, 25)] {
                let folder = dir.appendingPathComponent(label)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for i in 1...count {
                    let shift = jitter == 0 ? i : jitter + i
                    try Self.png(r: UInt8(min(255, rgb.0 + (label == "red" ? shift : 0))), g: UInt8(rgb.1 + shift % 10),
                                 b: UInt8(min(255, rgb.2 + (label == "blue" ? shift : 0)))).write(to: folder.appendingPathComponent("\(label)\(i).png"))
                }
            }
        }
        let job = TrainingJob(task: .imageClassification, datasetFileURL: train, textOrFeatureColumns: [], labelColumn: "",
                              validationFraction: 0.2, outputName: "live-image-\(UUID().uuidString.prefix(6))")
        let result = try await CreateMLTrainingProvider().train(job: job) { _ in }
        let modelURL = ArtifactStore().absoluteURL(for: result.modelFileRelativePath, in: .models)
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let items = try ImageHoldout.collect(imagePaths: nil, folder: held.path)
        let predictions = try ModelLabModule.predictImages(modelURL: modelURL, images: items.map(\.url))
        let report = ImageHoldout.report(images: items, results: predictions)
        print("LIVE-IMAGE-REPORT\n\(report)")
        #expect(items.count == 8)
        #expect(report.contains("Accuracy against folder names: 8/8 = 100.0%"))
    }

    private static func png(r: UInt8, g: UInt8, b: UInt8) throws -> Data {
        var pixels = [UInt8](); for _ in 0..<(64 * 64) { pixels += [r, g, b, 255] }
        guard let ctx = CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
        return data as Data
    }
}
