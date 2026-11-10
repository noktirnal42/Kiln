import SwiftUI

extension Activity { static let images = Activity("images") }

/// Image studio: generate, edit and upscale images; download models. Tools are `image_*` (see `ImageAgentTools`).
enum ImageStudioActivity {
    static let descriptor = ActivityDescriptor(
        id: "images", title: "Images", symbol: "photo.artframe",
        summary: "Generate, edit and upscale images; download FLUX, SDXL and other models",
        moduleIdentifier: ImageStudioModule.identifier,
        starterPrompts: { _ in
            [StarterPrompt(title: "What can I generate with?", symbol: "photo.artframe",
                           text: "Use image_list_models and tell me which engines are ready and which model I should download first."),
             StarterPrompt(title: "Generate an image", symbol: "wand.and.stars", text: "Use image_generate to make an image of: ")]
        },
        toolPrefixes: [ImageAgentTools.prefix],
        agentPromptSentence: "The image_* tools list image engines and models, download models, generate, edit and upscale images (downloads and generation need approval; never accept a model licence for the user).",
        capabilities: [
            .tool("image_list_models", "List engines, models and the catalogue", .read),
            .tool("image_history", "List generated pictures and their settings", .read),
            .tool("image_download_model", "Download a catalogue model", .write),
            .tool("image_generate", "Generate images from a prompt", .write),
            .tool("image_edit", "Image to image, inpaint, outpaint", .write),
            .tool("image_upscale", "Lanczos upscale", .write),
            .exempt("images.search-remote", "Search Hugging Face, Civitai and Draw Things' list", .read,
                    because: "Gap: the agent only sees the curated catalogue; remote search results carry untrusted descriptions and need a vetted adapter."),
            .exempt("images.prompt-library", "Save prompts and styles", .write,
                    because: "Gap: prompt and style library edits are GUI-only; image_generate accepts a style name."),
            .exempt("images.queue-controls", "Cancel or clear queued generations", .write,
                    because: "image_generate runs to completion inside one tool call; the visible queue is for GUI jobs."),
            .exempt("images.send-to-media", "Send a picture to the Media gallery", .write,
                    because: "Gap: no tool yet; the file path from image_history can be opened with media_open."),
        ],
        focusRequestCount: { app in (app.uiModules[ImageStudioModule.identifier] as? ImageStudioModule)?.openRequests ?? 0 },
        registerTools: { context in
            guard let images = await context.module(ImageStudioModule.identifier, as: ImageStudioModule.self) else { return }
            ImageAgentTools.register(module: images, into: context.registry)
        })
}
