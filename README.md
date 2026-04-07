# Cereal Notes

A minimal macOS menu bar app that captures meeting audio, transcribes it locally, generates AI-powered summaries, and exports clean Markdown to the notes app of your choice.

**No accounts. No cloud dependency. No lock-in.**

## How It Works

1. **Capture** — Records system audio + mic from any meeting app (Zoom, Meet, Teams, Slack, FaceTime) via ScreenCaptureKit
2. **Transcribe** — Runs locally on-device with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — audio never leaves your machine
3. **Summarize** — Sends transcript to an LLM of your choice (BYOK: Claude, OpenAI, Ollama) for summaries and action items
4. **Export** — Drops a structured `.md` file wherever you want it (Obsidian vault, Notion, Apple Notes, a folder)

## Example Output

```markdown
---
date: 2026-04-03
duration: 47m
participants: [Dylan, Sarah, Marcus]
source: capsule
---

# Weekly Sync — April 3, 2026

## Summary
The team reviewed Q2 planning priorities and agreed to consolidate
the onboarding flow into a single page...

## Key Decisions
- Consolidate onboarding to a single-page flow
- Delay API migration to next sprint

## Action Items
- [ ] Dylan — Draft revised onboarding spec by April 7
- [ ] Sarah — Schedule follow-up with design for onboarding mockups

## Transcript
**[00:00]** Dylan: Alright, let's get started...
```

## Requirements

- macOS 13+ (Ventura)
- Apple Silicon (M1+) recommended for optimal transcription performance
- Screen Recording & Microphone permissions

## Tech Stack

- **Language:** Swift (SwiftUI)
- **Audio Capture:** ScreenCaptureKit + AVAudioEngine
- **Transcription:** whisper.cpp (bundled, base.en model ~142 MB)
- **AI Processing:** Bring Your Own Key (Claude, OpenAI, Ollama, any OpenAI-compatible endpoint)
- **No Electron. No web views.**

## Roadmap

| Version | Focus |
|---------|-------|
| v0.1 | Menu bar shell, audio capture, local transcription, raw transcript export |
| v0.2 | BYOK AI summaries, action items, YAML frontmatter, custom prompts |
| v0.3 | Global hotkeys, auto-export, model selection, Ollama support |
| v0.4 | Homebrew cask, docs, contribution guide, template system |

## Non-Goals

- **Not a notes app.** Exports and gets out of the way.
- **Not cross-platform.** macOS only by design.
- **Not real-time transcription.** Processing happens post-meeting.

## Privacy

- All transcription runs locally
- No analytics, no telemetry
- Audio is deleted after export by default
- Network calls only happen for opt-in LLM API requests

## License

MIT
