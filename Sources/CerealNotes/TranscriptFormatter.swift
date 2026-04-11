import Foundation

enum TranscriptFormatter {
    static func header(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "# Meeting - \(formatter.string(from: date))\n\n"
    }

    static func entry(speaker: String, timestamp: TimeInterval, text: String) -> String {
        "**\(speaker)** (\(formatTimestamp(timestamp))): \(text)\n\n"
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
