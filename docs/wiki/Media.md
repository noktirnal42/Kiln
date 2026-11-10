# Media

The **Media** activity (⌘0) is a viewer and a small production toolbox.

- **Viewer:** AVKit video with scrub and 0.5 to 2x speed, zoomable images, audio with a waveform. It opens workspace files, drops and agent results.
- **Gallery** of generated items in `~/Library/Application Support/Kiln/Media`.
- **Text to speech** to a file (AVSpeechSynthesizer) and **speech to text** from a file. The composer's microphone button remains the dictation control.
- **Image generation** behind a provider protocol: Apple Image Playground when this Mac has it, otherwise a custom OpenAI-compatible `/images/generations` endpoint. With neither configured the call fails and says why; nothing is faked.

Agent tools: `media_open`, `media_list` (read); `media_generate_image`, `media_speak`, `media_transcribe` (write, need approval). There is no agent tool to delete library items.

## Limits

The custom image endpoint path is **unverified against a live endpoint**. A full image studio (model catalog, downloads, local engines) is on the [[Roadmap]] and is not part of this build.

---

**Verified status.** A real MP4 played in the viewer; a text to speech then speech to text round trip returned the spoken sentence (`docs/11-CURRENT-STATE.md`); Media tests are in `Tests/MediaTests`. **Not checked:** image generation against Apple Image Playground or a live endpoint in this pass, and batch transcription.
