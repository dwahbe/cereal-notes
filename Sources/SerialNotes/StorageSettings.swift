import AppKit
import Foundation

@MainActor @Observable
final class StorageSettings {
    private static let storageKey = "storageLocation"
    private static let saveAudioFilesKey = "storage.saveAudioFiles"

    var storageLocation: URL {
        didSet {
            UserDefaults.standard.set(storageLocation.path(percentEncoded: false), forKey: Self.storageKey)
        }
    }

    var saveAudioFiles: Bool {
        didSet {
            UserDefaults.standard.set(saveAudioFiles, forKey: Self.saveAudioFilesKey)
        }
    }

    var storageLocationName: String {
        storageLocation.lastPathComponent
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.storageKey) {
            self.storageLocation = URL(fileURLWithPath: path)
        } else {
            self.storageLocation = Self.defaultLocation
        }
        self.saveAudioFiles = defaults.object(forKey: Self.saveAudioFilesKey) as? Bool ?? true
    }

    private static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SerialNotes")
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Select"
        panel.message = "Choose where to save recordings"

        // Temporarily become a regular app so the panel can come to front
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        panel.level = .modalPanel

        if panel.runModal() == .OK, let url = panel.url {
            storageLocation = url
        }

        // Return to accessory (menu bar only) mode
        NSApp.setActivationPolicy(.accessory)
    }
}
