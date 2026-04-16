# CLAUDE.md

## What is this?

Cereal Notes — a menu bar-only macOS app that captures meeting audio, transcribes locally, and exports Markdown. See `README.md` for full product context.

## Build & Run

```bash
./scripts/run.sh          # build + wrap as .app + launch (dev loop)
./scripts/build-app.sh    # build + wrap only, don't launch
swift test                # unit tests (SwiftPM — no .app needed)
```

**Why scripts, not `swift run`:** SwiftPM executable targets compile to a raw
binary. macOS LaunchServices-gated APIs (Login Items, URL schemes,
`UNUserNotificationCenter`, TCC prompts tied to a bundle ID) require the
binary to live inside a proper `.app` bundle with a sibling
`Contents/Info.plist`. The scripts build the SwiftPM binary, wrap it into
`.build/CerealNotes.app`, ad-hoc sign it with entitlements, and register it
with LaunchServices. This mirrors the pattern used by
[CodexBar](https://github.com/steipete/CodexBar) and other shipping
SwiftPM-native menu bar apps.

**Never use `swift run`** — it produces a raw binary that crashes on any
LaunchServices-gated call (`bundleProxyForCurrentProcess is nil`).

**Xcode usage:** open `Package.swift` in Xcode as an editor only. To run,
invoke `./scripts/run.sh` from a terminal. Do not press Run in Xcode — it
builds a raw binary in DerivedData that registers under the same bundle ID
as the wrapped `.app`, leading to duplicate menu bar icons and traced
(frozen) processes. `run.sh` purges any DerivedData build it finds.

Requires **Xcode 26+** and **macOS 26+**. Swift tools version 6.2.

## Project Structure

```
Package.swift              # SwiftPM manifest (executable + tests + ObjC module)
scripts/
  build-app.sh             # swift build → wrap into .app → codesign → lsregister
  run.sh                   # kill existing instance → build-app.sh → open .app
Sources/
  CerealNotes/             # Main app target (SwiftUI executable)
    CerealNotesApp.swift            # Entry point, MenuBarExtra scene,
                                    #   kicks off model download at launch
    MenuBarView.swift               # Popover UI (idle + recording states)
    RecordingState.swift            # Observable recording state + timer
    StorageSettings.swift           # Storage location persistence + NSOpenPanel
    AudioCaptureService.swift       # Audio capture (process tap + SCK fallback)
    TranscriptionService.swift      # FluidAudio ASR + diarizer actor
    TranscriptFormatter.swift       # Markdown transcript rendering
    ModelDownloadState.swift        # Observable status for model prefetch
    MeetingDetectionService.swift   # Fuses NSWorkspace + CoreAudio mic signal
    MeetingBannerWindow.swift       # Floating NSPanel banner (primary prompt)
    MeetingNotifier.swift           # Legacy UNUserNotification fallback
                                    #   (runs in parallel with the banner)
    Info.plist                      # Real bundle plist (copied into .app)
    CerealNotes.entitlements        # Applied via codesign in build-app.sh
  SystemAudioTap/          # ObjC module wrapping CoreAudio tap API
Tests/
  AudioPipelineTests/      # Audio pipeline tests (swift test — no .app needed).
                           #   Some CoreAudio tap tests fail under `swift test`
                           #   because TCC denies system audio capture to a
                           #   non-bundled binary. Expected; transcription +
                           #   mic-engine + full-pipeline suites still pass.
```

## Architecture

- **SwiftUI** with `@Observable` (Swift 6 concurrency). All UI types are `@MainActor`.
- **Two capture paths**: `AudioCaptureService` tries a CoreAudio process tap first (ObjC `SystemAudioTap` module), falls back to ScreenCaptureKit.
- **State**: `RecordingState` owns the `AudioCaptureService` and drives the UI. `StorageSettings` manages the output directory via UserDefaults.
- **Transcription**: [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet streaming ASR + LS-EEND DIHARD III diarizer, both on-device. Models are cached in `~/Library/Application Support/FluidAudio/Models/`. Download is kicked off at app launch from `CerealNotesApp.init` (not popover open) so the banner can record without requiring the user to open the popover first. `RecordingState.start()` also awaits `downloadModelsIfNeeded()` as a safety net — idempotent, so no double-download.
- **Meeting detection**: `MeetingDetectionService` fuses two local signals — NSWorkspace launch/terminate/activate notifications (known meeting app bundle IDs) and a CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` listener on the default input device (mic in use). Known bundle IDs: Zoom, Microsoft Teams (v1 + v2), FaceTime, Slack, Webex, Discord.
- **Detection state machine — sticky attribution**: once the mic goes active, the service locks onto one bundle ID (chosen via frontmost → most-recently-activated → alphabetical fallback — never `Set.first`, which is non-deterministic). While the mic stays continuously active, frontmost/activation changes do **not** re-attribute. This prevents "Slack call detected" when Zoom warm-holds the mic at end-of-call and the user switches to Slack. If the locked app terminates mid-window, detection clears but does not hunt for a replacement. Mic inactivity is the only reset.
- **Dismiss / Stop-while-in-call**: both flip a `userRejectedThisWindow` flag so no further prompts fire until the mic cycles (signals a new call). Stopping a recording mid-call implicitly counts as dismiss — we don't re-prompt the user who just chose to stop.
- **Prompt surface**: `MeetingBannerController` renders a custom borderless `NSPanel` (Granola-style) in the top-right of the active screen. `.statusBar` level + `canJoinAllSpaces + fullScreenAuxiliary` collection so it floats over fullscreen Zoom and follows spaces. Auto-dismisses after 15s. `MeetingNotifier` (`UNUserNotificationCenter`) currently runs in parallel as a fallback; scheduled for removal.
- **No networking**. Everything runs locally (model downloads from Hugging Face on first launch are the only exception).

## Design

See **[DESIGN.md](DESIGN.md)** for all frontend and design decisions (Liquid Glass rules, layout constants, typography, icon conventions).

## Conventions

- Target macOS 26 APIs freely — no backwards compatibility needed
- `Info.plist` is a real file copied into `.app/Contents/` by `build-app.sh` (no linker `__info_plist` hack)
- `CerealNotes.entitlements` is applied via `codesign --entitlements` in `build-app.sh` — currently only `com.apple.security.device.audio-input`
- Bundle ID: `com.cerealnotes.app`
- Audio output: timestamped session directories containing `system.wav` + `mic.wav` (48kHz mono float32) alongside a streaming `transcript.md`
- Permissions reset when the `.app` path changes (different worktree = different path = TCC re-prompts). Expected.
- `UNUserNotificationCenter` is wired but not the primary surface. New meeting prompts should extend `MeetingBannerController`; don't add new notification flows unless you've thought through Focus/DND filtering and notification permission UX.
