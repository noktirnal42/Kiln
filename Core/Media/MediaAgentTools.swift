import Foundation

/// Media as agent and MCP tools. Viewing is a read; generating images, speaking and transcribing produce files or use
/// the recogniser, so they are writes and go through approval like `edit_file`.
public enum MediaAgentTools {
    public static let prefix = "media_"

    @MainActor
    public static func register(module: MediaModule, into registry: ToolRegistry = .shared) {
        for kind in Kind.allCases { registry.register(MediaAgentTool(kind: kind, module: module)) }
    }

    enum Kind: String, CaseIterable, Sendable {
        case open, list, generateImage = "generate_image", speak, transcribe

        var spec: ToolSpec {
            switch self {
            case .open:
                ToolSpec(name: "media_open", summary: "Show a video, image or audio file in Kiln's Media viewer (video with scrub and speed, images with zoom, audio with a waveform). Give either a file path or a gallery id from media_list. Changes nothing on disk.",
                         parameters: [
                            ToolParam(name: "path", description: "Absolute path, or relative to the project folder", required: false),
                            ToolParam(name: "gallery_id", description: "Item id from media_list", required: false),
                         ], permission: .read)
            case .list:
                ToolSpec(name: "media_list", summary: "List what is in Kiln's media gallery (generated images and spoken audio) with ids, kinds, file paths and the prompts that made them.",
                         parameters: [ToolParam(name: "limit", type: "integer", description: "Most recent first; default 25", required: false)],
                         permission: .read)
            case .generateImage:
                ToolSpec(name: "media_generate_image", summary: "Generate an image from a text prompt with a configured image provider (Apple Image Playground on this Mac when available, or the user's custom endpoint if it serves /images/generations) and save it in the media gallery. If no provider is usable the call fails and says why; nothing is faked. Writes a file; requires approval.",
                         parameters: [
                            ToolParam(name: "prompt", description: "What to draw"),
                            ToolParam(name: "count", type: "integer", description: "How many images, 1–4; default 1", required: false),
                            ToolParam(name: "provider", description: "Provider id, e.g. apple-image-playground or custom-endpoint-images; default: first available", required: false),
                         ], permission: .write)
            case .speak:
                ToolSpec(name: "media_speak", summary: "Turn text into speech with the system voices and save the audio in the media gallery. Set play=true to also say it aloud on this Mac. Writes a file; requires approval.",
                         parameters: [
                            ToolParam(name: "text", description: "The text to speak (markdown and code blocks are tidied or skipped)"),
                            ToolParam(name: "voice", description: "AVSpeechSynthesisVoice identifier; default: the best installed voice for the system language", required: false),
                            ToolParam(name: "rate", type: "number", description: "0.0–1.0, default 0.5", required: false),
                            ToolParam(name: "play", type: "boolean", description: "Also play it aloud now; default false", required: false),
                         ], permission: .write)
            case .transcribe:
                ToolSpec(name: "media_transcribe", summary: "Transcribe speech in an audio (or video) file with Apple's recogniser, on this Mac when the language model is installed. The user must have allowed Speech Recognition for Kiln; if not, the call says so. Requires approval.",
                         parameters: [ToolParam(name: "path", description: "Absolute path, or relative to the project folder")],
                         permission: .write)
            }
        }
    }

    static func resolve(_ path: String, workspace: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return (workspace ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(expanded)
    }
}

struct MediaAgentTool: ToolExecuting {
    let kind: MediaAgentTools.Kind
    let module: MediaModule
    var spec: ToolSpec { kind.spec }

    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        let gallery = await MainActor.run { module.gallery }
        switch kind {
        case .open:
            if let raw = args["gallery_id"] as? String, !raw.isEmpty {
                guard let id = UUID(uuidString: raw), let item = gallery.item(id: id) else {
                    throw MediaToolError.message("No gallery item with id \(raw). Use media_list.")
                }
                let url = gallery.fileURL(for: item)
                let kind = try await MainActor.run { try module.openForAgent(url) }
                return "Opened \(kind.rawValue) \(item.title) in the Media viewer (\(url.path))."
            }
            let path = try Self.required(args, "path")
            let url = MediaAgentTools.resolve(path, workspace: context.workspaceRoot)
            let kind = try await MainActor.run { try module.openForAgent(url) }
            return "Opened \(kind.rawValue) \(url.lastPathComponent) in the Media viewer."
        case .list:
            let limit = max(1, min(200, (args["limit"] as? Int) ?? 25))
            let items = gallery.items().prefix(limit)
            guard !items.isEmpty else { return "The media gallery is empty." }
            return items.map { item in
                "\(item.id.uuidString) · \(item.kind.rawValue) · \(item.origin.rawValue) · \(gallery.fileURL(for: item).path)"
                    + (item.prompt.map { " · \"\($0.prefix(80))\"" } ?? "")
            }.joined(separator: "\n")
        case .generateImage:
            let prompt = try Self.required(args, "prompt")
            let count = (args["count"] as? Int) ?? 1
            let provider = args["provider"] as? String
            let saved = try await module.generateImages(prompt: prompt, count: count, providerID: provider)
            let lines = saved.map { "\($0.id.uuidString) · \(gallery.fileURL(for: $0).path)" }
            return "Generated \(saved.count) image(s) with \(saved.first?.provider ?? "?"):\n" + lines.joined(separator: "\n")
        case .speak:
            let text = try Self.required(args, "text")
            let rate = (args["rate"] as? Double).map(Float.init) ?? (args["rate"] as? Int).map(Float.init)
            let (item, duration) = try await module.speak(text, voiceID: args["voice"] as? String, rate: rate, play: (args["play"] as? Bool) ?? false)
            return "Saved \(String(format: "%.1f", duration)) s of speech: \(item.id.uuidString) · \(gallery.fileURL(for: item).path)"
        case .transcribe:
            let path = try Self.required(args, "path")
            let url = MediaAgentTools.resolve(path, workspace: context.workspaceRoot)
            return try await module.transcribe(url)
        }
    }

    private static func required(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaToolError.message("\(key) is required.")
        }
        return value
    }
}

enum MediaToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}
