# Cereal Notes

A minimal macOS menu bar app that captures meeting audio, transcribes it locally, and exports clean Markdown to the notes app of your choice.

**No accounts. No cloud dependency. No lock-in.**

## Principles

1. **Hidden.** Doesn't bother the user and doesn't show up in meeting apps.
2. **Safe.** Data never leaves your laptop unless you want it to.
3. **Simple.** Cereal produces a high quality meeting transcript. What you do with it afterwards is up to you.

## How It Works

1. **Capture** — Records system audio + mic from any meeting app (Zoom, Meet, Teams, Slack, FaceTime) via ScreenCaptureKit
2. **Transcribe** — Runs locally on-device using Apple's [Speech framework](https://developer.apple.com/documentation/speech) (`SFSpeechRecognizer`) — audio never leaves your machine
3. **Export** — Drops a structured `.md` file wherever you want it (Obsidian vault, Notion, Apple Notes, a folder)

## Example Output

```markdown
---
date: 2026-04-03
duration: 47m
---

# Meeting — 2026-04-03 10:00 AM

## Transcript
**[00:00]** Dylan: Alright, let's get started...
**[00:15]** Sarah: I wanted to flag something on the onboarding flow...
```

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon (M1+) recommended for optimal transcription performance
- Screen Recording & Microphone permissions

## Tech Stack

- **Language:** Swift (SwiftUI)
- **Audio Capture:** ScreenCaptureKit + AVAudioEngine
- **Transcription:** Apple Speech framework (`SFSpeechRecognizer`, on-device)
- **No Electron. No web views.**

## Roadmap

| Version | Focus                                                                     |
|---------|---------------------------------------------------------------------------|
| v0.1    | Menu bar shell, audio capture, local transcription, raw transcript export |
| v0.2    | AI summaries, action items, YAML frontmatter, custom prompts              |
| v0.3    | Global hotkeys, auto-export, Ollama support                               |
| v0.4    | Homebrew cask, docs, contribution guide, template system                  |

## Non-Goals

- **Not a notes app.** Exports and gets out of the way.
- **Not cross-platform.** macOS only by design.

## Privacy

- All transcription runs locally
- No analytics, no telemetry
- Audio is retained indefinitely on-device

## License

MIT
