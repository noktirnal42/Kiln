import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ModelLabCore

struct TrainingProviderTests {
    @Test func rejectsInvalidSmallLMShapeBeforeTraining() {
        let job = SmallLMPretrainingJob(
            corpusText: String(repeating: "model lab ", count: 100),
            dimensions: 127,
            numHeads: 4,
            outputName: "invalid"
        )

        #expect(throws: SmallLMError.self) {
            try SmallLMPretrainingProvider.validate(job: job)
        }
    }

    @Test func trainsImageClassifierOnLabeledSubfolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let red = root.appendingPathComponent("red", isDirectory: true)
        let blue = root.appendingPathComponent("blue", isDirectory: true)
        try FileManager.default.createDirectory(at: red, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blue, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 1...8 {
            try makeSolidColorPNG(red: 200, green: 30, blue: 30)
                .write(to: red.appendingPathComponent("r\(index).png"))
            try makeSolidColorPNG(red: 30, green: 30, blue: 200)
                .write(to: blue.appendingPathComponent("b\(index).png"))
        }

        let provider = CreateMLTrainingProvider()
        #expect(provider.supportedTasks.contains(.imageClassification))

        let job = TrainingJob(
            task: .imageClassification,
            datasetFileURL: root,
            textOrFeatureColumns: [],
            labelColumn: "",
            validationFraction: 0.25,
            outputName: "test-image-classifier-\(UUID().uuidString.prefix(6))"
        )

        let result = try await provider.train(job: job) { _ in }

        #expect(result.trainingAccuracy >= 0 && result.trainingAccuracy <= 1)
        #expect(result.validationAccuracy >= 0 && result.validationAccuracy <= 1)

        let artifactStore = ArtifactStore()
        let modelURL = artifactStore.absoluteURL(for: result.modelFileRelativePath, in: .models)
        #expect(FileManager.default.fileExists(atPath: modelURL.path))
        try? FileManager.default.removeItem(at: modelURL)
    }

    private func makeSolidColorPNG(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let width = 32
        let height = 32
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(red)
            pixels.append(green)
            pixels.append(blue)
            pixels.append(255)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return mutableData as Data
    }
}
