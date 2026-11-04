# Launch marketing assets (drafts)

Nothing here is posted or published. The maintainer approves all posting. Written 2026-11-03 against Kiln 0.1.1.

| File | What |
|---|---|
| `VIDEO-SCRIPT.md` | 90 s demo: script, shot list, checklist, ffmpeg assembly |
| `CLIPS.md` | Three under-30 s clips, storyboards |
| `LAUNCH-COPY.md` | Drafts per community, Show HN comment, social thread |
| `../../Scripts/make_marketing_loop.py` | Builds `site/assets/kiln-approval-loop.mp4` from stills |

## Captured for real (2026-11-03)

- `site/assets/shots/audit-chain.png`: a crop of the running Kiln 0.1.1 Audit view (chain event count and head hash). Real app, no agent run behind it.
- Already existing: `approval-crop.jpg` (real Mac approval queue). `watch-approval.png`, `watch-reply.png`, `iphone-*.png` are **simulator demo data**.
- `site/assets/kiln-approval-loop.mp4`: an 18 s muted draft slideshow of the three stills above with captions that state which are real and which are simulator. It is a placeholder, **not** the demo video; do not use it as proof of the watch flow. Rebuild with `python3 Scripts/make_marketing_loop.py`.

## Not captured; to record

- The 90 s demo and all three clips: needs a real watch and phone, a configured relay and push key, and a hosted tool-capable model. The installed app's agent models today are a free hosted model whose last run stopped without an answer, so a staged take needs a better model first.
- A real `via: remote` Audit row on screen. The current Audit view has "No agent activity recorded yet" for this session.
- A README hero GIF from real footage (the ffmpeg commands are in `VIDEO-SCRIPT.md`).
