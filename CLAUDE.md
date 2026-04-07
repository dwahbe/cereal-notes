# CLAUDE.md

## What is this?

Cereal Notes — a menu bar-only macOS app that captures meeting audio, transcribes locally, and exports Markdown. See `README.md` for full product context.

## Build & Run

```bash
swift build        # build
swift run          # run (needs Screen Recording + Mic permissions in System Settings)
swift test         # run tests
```

Requires **Xcode 26+** and **macOS 26+**. Swift tools version 6.2.

## Project Structure

```
Sources/
  CerealNotes/           # Main app target (SwiftUI executable)
    CerealNotesApp.swift  # Entry point, MenuBarExtra scene
    MenuBarView.swift     # Popover UI (idle + recording states)
    RecordingState.swift  # Observable recording state + timer
    StorageSettings.swift # Storage location persistence + NSOpenPanel
    AudioCaptureService.swift  # Audio capture (process tap + SCK fallback)
    Info.plist            # Bundle config (embedded via linker flags)
  SystemAudioTap/        # ObjC module wrapping CoreAudio tap API
Tests/
  AudioPipelineTests/    # Audio pipeline tests
```

## Architecture

- **SwiftUI** with `@Observable` (Swift 6 concurrency). All UI types are `@MainActor`.
- **Two capture paths**: `AudioCaptureService` tries a CoreAudio process tap first (ObjC `SystemAudioTap` module), falls back to ScreenCaptureKit.
- **State**: `RecordingState` owns the `AudioCaptureService` and drives the UI. `StorageSettings` manages the output directory via UserDefaults.
- **No networking**. Everything runs locally.

## Design

See **[DESIGN.md](DESIGN.md)** for all frontend and design decisions (Liquid Glass rules, layout constants, typography, icon conventions).

## Conventions

- Target macOS 26 APIs freely — no backwards compatibility needed
- Info.plist is embedded into the binary via linker flags (not Xcode build phases)
- Bundle ID: `com.cerealnotes.app`
- Audio output: timestamped session directories containing `system.wav` + `mic.wav` (48kHz mono float32)
