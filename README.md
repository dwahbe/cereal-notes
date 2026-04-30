# Serial Notes

A minimal macOS menu bar app that captures meeting audio, transcribes it locally, and exports clean Markdown to the notes app of your choice.

**No accounts. No cloud dependency. No lock-in.**

## Principles

1. **Hidden.** Doesn't bother the user and doesn't show up in meeting apps.
2. **Safe.** Data never leaves your laptop unless you want it to.
3. **Simple.** Serial Notes produces a high quality meeting transcript. What you do with it afterwards is up to you.

## How It Works

1. **Detect** — Notices when a meeting app (Zoom, Meet, Teams, FaceTime, Slack, Webex, Discord) starts using the mic and offers a one-click record banner.
2. **Capture** — Records system audio via a CoreAudio process tap (no screen-recording prompt), with a ScreenCaptureKit fallback. Mic is captured in parallel via AVAudioEngine.
3. **Transcribe** — Runs locally on-device using [FluidAudio](https://github.com/FluidInference/FluidAudio): Parakeet streaming ASR for real-time text, LS-EEND for speaker diarization. Audio never leaves your machine.
4. **Export** — Writes a structured `transcript.md` alongside the raw `system.wav` + `mic.wav` into a session folder in your chosen storage location (Obsidian vault, iCloud, any folder).

## Example Output

```markdown
---
date: 2026-04-24
duration: 47m
---

# Meeting — 2026-04-24 at 10:00 AM

**You** (00:00:00): Alright, let's get started...
**Person 1** (00:00:15): I wanted to flag something on the onboarding flow...
**You** (00:00:42): Yeah, I saw that too — let's dig in.
```

Each session lives in its own folder:

```
~/Serial Notes/2026-04-24 at 10.00.00 AM/
├── transcript.md     # what you share
├── system.wav        # raw meeting-side audio
└── mic.wav           # raw mic audio
```

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon (M1+) — required for CoreML model performance
- Xcode 26+ (Swift tools 6.2)
- Microphone + System Audio Recording permissions
- ~1 GB free disk space for transcription models (downloaded from Hugging Face on first launch)

## Running locally

```bash
./scripts/run.sh          # build + wrap as .app + launch
./scripts/build-app.sh    # build + wrap only
swift test                # run tests
```

The app is built via SwiftPM and wrapped into a proper `.app` bundle by the build script. LaunchServices-gated APIs (menu bar extras, URL schemes, notification center) require the binary to live inside a signed `.app`, so **don't use `swift run`** — it produces a raw binary that can't register with LaunchServices and crashes on first TCC-gated call.

On first launch, models are prefetched in the background from Hugging Face (~1 GB) so the record button is ready when a meeting starts.

## Tech Stack

- **Language:** Swift 6 / SwiftUI (`@Observable`, `@MainActor`, actor-isolated services)
- **Audio Capture:** CoreAudio process tap (primary) → ScreenCaptureKit fallback; AVAudioEngine for mic
- **Transcription:** [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet EOU streaming ASR (160ms chunks, on-device CoreML)
- **Diarization:** FluidAudio LS-EEND (DIHARD III) on both mic and system streams
- **No Electron. No web views. No networking after model download.**

## Roadmap

| Version | Focus                                                                     |
|---------|---------------------------------------------------------------------------|
| v0.1    | Menu bar shell, audio capture, local transcription, diarization           |
| v0.2    | AI summaries, action items, custom prompts                                |
| v0.3    | Global hotkeys, auto-export, Ollama support                               |
| v0.4    | Cross-session speaker identity, keyword biasing, Homebrew cask            |

## Non-Goals

- **Not a notes app.** Exports and gets out of the way.
- **Not cross-platform.** macOS only by design.

## Privacy

- All transcription runs locally on-device
- No analytics, no telemetry
- Models are downloaded once from Hugging Face; after that, nothing leaves your machine
- Audio is retained indefinitely on-device (delete session folders to clean up)

## License

MIT
