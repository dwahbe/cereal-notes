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
    CerealNotesApp.swift              # Entry point, MenuBarExtra + Settings scenes,
                                      #   kicks off model download at launch
    MenuBarView.swift                 # Popover UI (idle + recording states)
    SettingsView.swift                # Settings window (General + Voices tabs)
    RecordingState.swift              # Observable recording state + timer
    StorageSettings.swift             # Storage location persistence + NSOpenPanel
    AudioCaptureService.swift         # Audio capture (process tap + SCK fallback)
    TranscriptionService.swift        # FluidAudio ASR + diarizer actor,
                                      #   applies punctuation via TranscriptRewriter
    TranscriptRewriter.swift          # Foundation Models on-device LLM that restores
                                      #   punctuation + capitalization per EOU utterance,
                                      #   with a heuristic fallback when AI unavailable
    TranscriptFormatter.swift         # Markdown transcript rendering
    ModelDownloadState.swift          # Observable status for model prefetch
    MeetingDetectionService.swift     # Fuses NSWorkspace + CoreAudio mic signal
    MeetingBannerWindow.swift         # Floating NSPanel banner (primary prompt)
    MeetingNotifier.swift             # Legacy UNUserNotification fallback
                                      #   (runs in parallel with the banner)
    VoiceProfile.swift                # Profile data type (.you / .other)
    VoiceProfileStore.swift           # On-disk profile store (JSON + WAV pairs)
    VoiceEnrollmentRecorder.swift     # @Observable mic recorder used by enrollment
    VoiceEnrollmentFlowView.swift     # Face-ID-style guided enrollment flow
    Info.plist                        # Real bundle plist (copied into .app)
    CerealNotes.entitlements          # Applied via codesign in build-app.sh
  SystemAudioTap/          # ObjC module wrapping CoreAudio tap API
Tests/
  AudioPipelineTests/      # Swift test suites (swift test — no .app needed).
                           #   Some CoreAudio tap tests fail under `swift test`
                           #   because TCC denies system audio capture to a
                           #   non-bundled binary. Expected; transcription,
                           #   mic-engine, full-pipeline, and rewriter suites pass.
    AudioPipelineTests.swift          # Capture path + aggregate device coverage
    CATapIntrospection.swift          # Tap descriptor + API roundtrip
    TapDeviceTests.swift              # Process-tap device creation
    TranscriptionTests.swift          # FluidAudio ASR + diarizer smoke tests
    TranscriptRewriterTests.swift     # Heuristic rewriter + FM smoke test
                                      #   (FM smoke test gated by CEREAL_FM_TEST=1)
```

## Architecture

- **SwiftUI** with `@Observable` (Swift 6 concurrency). All UI types are `@MainActor`.
- **Two capture paths**: `AudioCaptureService` tries a CoreAudio process tap first (ObjC `SystemAudioTap` module), falls back to ScreenCaptureKit.
- **State**: `RecordingState` owns the `AudioCaptureService` and drives the UI. `StorageSettings` manages the output directory via UserDefaults. `VoiceProfileStore` holds saved enrollment profiles.
- **Transcription**: [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet streaming ASR + LS-EEND DIHARD III diarizer, both on-device. Models are cached in `~/Library/Application Support/FluidAudio/Models/`. Download is kicked off at app launch from `CerealNotesApp.init` (not popover open) so the banner can record without requiring the user to open the popover first. `RecordingState.start()` also awaits `downloadModelsIfNeeded()` as a safety net — idempotent, so no double-download.
- **Punctuation + capitalization**: Parakeet emits raw lowercase with no punctuation. `TranscriptRewriter` closes the gap: on each EOU callback, `TranscriptionService` awaits the rewriter before appending to `pendingEntries`. The production implementation (`FoundationModelsRewriter`) is an actor around Apple's on-device `LanguageModelSession` (macOS 26+) using a `@Generable` schema + 2s timeout + strict word-equality guard (lowercased-alphanumeric compare) to reject hallucinations. When Apple Intelligence is unavailable (disabled, ineligible hardware, model not ready) the factory returns `HeuristicRewriter` — capitalize first char, append `.` if missing. The rewriter only runs on finalized utterances; live-partial UI stays raw.
- **Voice enrollment**: `VoiceProfileStore` persists profiles to `~/Library/Application Support/CerealNotes/voices/` as `<uuid>.json` + `<uuid>.wav` pairs. `VoiceEnrollmentRecorder` captures a short mic clip with per-phrase silence detection (RMS threshold + hangover) and advances through three phrases. `VoiceEnrollmentFlowView` is the Face-ID-style guided UI. On session start, `RecordingState` hands enrollment clips to `TranscriptionService.startSession(enrollments:)`, which primes each diarizer so matching voices get named instead of labeled `You` / `Person N`.
- **Detection suspend/resume**: any code that holds the mic for non-meeting purposes (currently just `VoiceEnrollmentRecorder`) must call `MeetingDetectionService.suspendDetection()` before engine start and `resumeDetection()` on stop. Otherwise enrollment audio would false-fire the "meeting detected" banner. Wiring lives in `SettingsView`'s `VoicesSettingsTab.onAppear`.
- **Settings scene**: a standard SwiftUI `Settings { … }` scene (not a bespoke window). `SettingsWindowChrome` observes the hosting NSWindow's `willCloseNotification` and restores `NSApp.setActivationPolicy(.accessory)`; without this, clicking the gear flips the app to `.regular` and leaves it visible in Dock + Cmd-Tab after the window closes.
- **Meeting detection**: `MeetingDetectionService` fuses two local signals — NSWorkspace launch/terminate/activate notifications (known meeting app bundle IDs) and a CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` listener on the default input device (mic in use). Known bundle IDs: Zoom, Microsoft Teams (v1 + v2), FaceTime, Slack, Webex, Discord.
- **Detection state machine — sticky attribution**: once the mic goes active, the service locks onto one bundle ID (chosen via frontmost → most-recently-activated → alphabetical fallback — never `Set.first`, which is non-deterministic). While the mic stays continuously active, frontmost/activation changes do **not** re-attribute. This prevents "Slack call detected" when Zoom warm-holds the mic at end-of-call and the user switches to Slack. If the locked app terminates mid-window, detection clears but does not hunt for a replacement. Mic inactivity is the only reset.
- **Dismiss / Stop-while-in-call**: both flip a `userRejectedThisWindow` flag so no further prompts fire until the mic cycles (signals a new call). Stopping a recording mid-call implicitly counts as dismiss — we don't re-prompt the user who just chose to stop.
- **Prompt surface**: `MeetingBannerController` renders a custom borderless `NSPanel` (Granola-style) in the top-right of the active screen. `.statusBar` level + `canJoinAllSpaces + fullScreenAuxiliary` collection so it floats over fullscreen Zoom and follows spaces. Auto-dismisses after 15s. `MeetingNotifier` (`UNUserNotificationCenter`) currently runs in parallel as a fallback; scheduled for removal.
- **No networking**. Everything runs locally. Exceptions: FluidAudio model downloads from Hugging Face on first launch, and Apple's on-device Foundation Models (which may pull its base model through system channels outside the app's control).

## Design

See **[DESIGN.md](DESIGN.md)** for all frontend and design decisions (Liquid Glass rules, layout constants, typography, icon conventions).

## Conventions

- Target macOS 26 APIs freely — no backwards compatibility needed
- `Info.plist` is a real file copied into `.app/Contents/` by `build-app.sh` (no linker `__info_plist` hack)
- `CerealNotes.entitlements` is applied via `codesign --entitlements` in `build-app.sh` — currently only `com.apple.security.device.audio-input`
- Bundle ID: `com.cerealnotes.app`
- Audio output: timestamped session directories containing `system.wav` + `mic.wav` (48kHz mono float32) alongside a streaming `transcript.md`
- Voice profile storage: `~/Library/Application Support/CerealNotes/voices/` — JSON + WAV pairs. Don't bake any other personal data into this directory.
- Permissions reset when the `.app` path changes (different worktree = different path = TCC re-prompts). Expected.
- `UNUserNotificationCenter` is wired but not the primary surface. New meeting prompts should extend `MeetingBannerController`; don't add new notification flows unless you've thought through Focus/DND filtering and notification permission UX.
- Any feature that opens the mic outside a recording session must call `MeetingDetectionService.suspendDetection()` / `resumeDetection()` around its engine lifetime — otherwise it false-fires the banner.
- Transcript post-processing (punctuation, anything else that mutates finalized text) belongs inside `TranscriptionService`'s EOU handlers, *before* `pendingEntries.append`. The 3-second flush delay (`flushOldEntries`) is enough headroom for async rewrites — do not add a separate post-write pass. Don't touch partial-transcript text; the live-partial UI is deliberately raw.
- The test target `@testable import CerealNotes`, so keep testable code at `internal` visibility; `private` types cannot carry `@Generable` or other macro-expanded conformances (moved out of `FoundationModelsRewriter` for this reason).
