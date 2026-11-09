import AVFoundation
import Foundation

/// Reduces an audio file to a fixed number of peak amplitudes (0…1) for drawing a waveform.
public enum Waveform {
    public static func peaks(of url: URL, buckets: Int = 600) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard buckets > 0,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration), duration.seconds > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        let totalSamples = max(1, Int(duration.seconds * 8000))
        let perBucket = max(1, totalSamples / buckets)
        var result = [Float](repeating: 0, count: buckets)
        var index = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let copied: OSStatus = data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard copied == kCMBlockBufferNoErr else { continue }
            data.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) {
                    let bucket = min(buckets - 1, index / perBucket)
                    let magnitude = Float(abs(Int32(sample))) / 32768
                    if magnitude > result[bucket] { result[bucket] = magnitude }
                    index += 1
                }
            }
        }
        let peak = result.max() ?? 0
        return peak > 0 ? result.map { $0 / peak } : result
    }
}
