import SwiftUI

extension Activity { static let media = Activity("media") }

/// Media: video, images and audio. Tools are `media_*` (see `MediaAgentTools`).
enum MediaActivity {
    static let descriptor = ActivityDescriptor(
        id: "media", title: "Media", symbol: "play.rectangle",
        summary: "Video, images and audio: view, generate, speak and transcribe",
        moduleIdentifier: MediaModule.identifier,
        starterPrompts: { _ in
            [StarterPrompt(title: "Generate an image", symbol: "photo", text: "Use media_generate_image to make an image of: "),
             StarterPrompt(title: "Read this aloud", symbol: "speaker.wave.2",
                           text: "Use media_speak to turn the following text into an audio file I can play: "),
             StarterPrompt(title: "Transcribe a recording", symbol: "waveform",
                           text: "Use media_transcribe on the audio file at this path and give me the transcript: ")]
        },
        toolPrefixes: [MediaAgentTools.prefix],
        agentPromptSentence: "The media_* tools open video, images and audio in the Media viewer, generate images, speak text and transcribe recordings (generating and transcribing need approval).",
        capabilities: [
            .tool("media_open", "Open a file in the viewer", .read),
            .tool("media_list", "List media files", .read),
            .tool("media_generate_image", "Generate an image", .write),
            .tool("media_speak", "Speak text to an audio file", .write),
            .tool("media_transcribe", "Transcribe a recording", .write),
            .exempt("media.playback-controls", "Play, seek, speed, zoom, waveform", .read,
                    because: "Interactive viewing controls; media_open with play and rate sets up playback for the agent."),
            .exempt("media.delete-item", "Delete a generated item", .write,
                    because: "Gap: deleting library items has no tool yet; destructive, so it needs an approval-gated adapter."),
            .exempt("media.reveal-copy", "Reveal in Finder, copy", .read,
                    because: "Hand-off to Finder and the clipboard for the user; the agent already has the file path from media_list."),
        ],
        focusRequestCount: { app in (app.uiModules[MediaModule.identifier] as? MediaModule)?.openRequests ?? 0 },
        registerTools: { context in
            guard let media = await context.module(MediaModule.identifier, as: MediaModule.self) else { return }
            MediaAgentTools.register(module: media, into: context.registry)
            #if DEBUG
            // Visual-QA hook, compiled out of release builds: open Kiln.app --args -KilnOpenMedia /path/to/file
            // shows the file in the Media viewer at launch.
            if let path = UserDefaults.standard.string(forKey: "KilnOpenMedia") {
                _ = try? media.openForAgent(URL(fileURLWithPath: path))
            }
            #endif
        })
}
