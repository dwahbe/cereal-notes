import AppKit
import AVFoundation
import Foundation

@MainActor @Observable
final class VoiceProfileStore {
    private(set) var profiles: [VoiceProfile] = []

    private let directory: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.directory = appSupport
            .appendingPathComponent("CerealNotes", isDirectory: true)
            .appendingPathComponent("voices", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        reload()
    }

    var yourProfile: VoiceProfile? {
        profiles.first(where: { $0.kind == .you })
    }

    var otherProfiles: [VoiceProfile] {
        profiles.filter { $0.kind == .other }.sorted { $0.name < $1.name }
    }

    // MARK: - CRUD

    func reload() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            profiles = []
            return
        }

        let decoder = JSONDecoder()
        var loaded: [VoiceProfile] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let profile = try? decoder.decode(VoiceProfile.self, from: data) else {
                continue
            }
            loaded.append(profile)
        }
        profiles = loaded
    }

    /// Save a profile, writing its JSON manifest + enrollment clip.
    /// If a profile of the same kind already exists for `.you`, it's replaced.
    func save(name: String, kind: VoiceProfile.Kind, clipURL: URL) throws -> VoiceProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? fallbackName(for: kind) : trimmed

        if kind == .you, let existing = yourProfile {
            try delete(existing)
        }

        let profile = VoiceProfile(name: resolvedName, kind: kind)

        let manifestURL = manifestURL(for: profile.id)
        let clipDestination = self.clipURL(for: profile.id)

        if FileManager.default.fileExists(atPath: clipDestination.path) {
            try FileManager.default.removeItem(at: clipDestination)
        }
        try FileManager.default.copyItem(at: clipURL, to: clipDestination)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: manifestURL, options: .atomic)

        reload()
        return profile
    }

    func rename(_ profile: VoiceProfile, to newName: String) throws {
        var updated = profile
        updated.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.name.isEmpty { updated.name = fallbackName(for: updated.kind) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: manifestURL(for: updated.id), options: .atomic)
        reload()
    }

    func delete(_ profile: VoiceProfile) throws {
        let manifest = manifestURL(for: profile.id)
        let clip = clipURL(for: profile.id)
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
        }
        if FileManager.default.fileExists(atPath: clip.path) {
            try FileManager.default.removeItem(at: clip)
        }
        reload()
    }

    // MARK: - Audio loading (for priming diarizers)

    /// Load a profile's enrollment clip as mono float32 samples.
    func loadClipSamples(for profile: VoiceProfile) -> (samples: [Float], sampleRate: Double)? {
        let url = clipURL(for: profile.id)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channelData = buffer.floatChannelData else { return nil }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))
        return (samples, format.sampleRate)
    }

    // MARK: - Paths

    private func manifestURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func clipURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func fallbackName(for kind: VoiceProfile.Kind) -> String {
        switch kind {
        case .you: return "You"
        case .other: return "Unnamed"
        }
    }
}
