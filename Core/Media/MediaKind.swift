import Foundation

/// What the Media viewer can show, decided from the file extension (AVKit and ImageIO decide the rest).
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video, image, audio

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "qt", "3gp"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "wave", "aif", "aiff", "caf", "aac", "flac", "mp4a"]

    public init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { self = .video }
        else if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.audioExtensions.contains(ext) { self = .audio }
        else { return nil }
    }

    public var symbol: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        }
    }

    public var title: String {
        switch self {
        case .video: "Video"
        case .image: "Image"
        case .audio: "Audio"
        }
    }
}

/// Failures the Media tools and views report in words, never as fake output.
public enum MediaError: LocalizedError, Equatable, Sendable {
    case noImageProvider(String)
    case providerFailed(String)
    case unsupportedFile(String)
    case fileMissing(String)
    case emptyText
    case speechNotAuthorised
    case recogniserUnavailable
    case noSpeechFound
    case synthesisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noImageProvider(let why):
            "No image provider is configured. \(why)"
        case .providerFailed(let why): "Image generation failed: \(why)"
        case .unsupportedFile(let name): "\(name) is not a video, image or audio file Kiln can show."
        case .fileMissing(let path): "No file at \(path)."
        case .emptyText: "There is no text to work with."
        case .speechNotAuthorised:
            "Speech Recognition is not allowed for Kiln. Allow it in System Settings → Privacy & Security → Speech Recognition."
        case .recogniserUnavailable: "Speech recognition is not available for this language on this Mac right now."
        case .noSpeechFound: "No speech was found in that recording."
        case .synthesisFailed(let why): "Speech could not be produced: \(why)"
        }
    }
}
