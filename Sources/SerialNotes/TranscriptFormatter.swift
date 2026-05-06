import Foundation

enum TranscriptFormatter {
    /// Produces a fixed-width header so it can be rewritten in place at end-of-session
    /// via `seek(toOffset: 0)`. Duration is always formatted `HHhMMmSSs`.
    static func header(date: Date, duration: TimeInterval) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "yyyy-MM-dd 'at' h:mm a"
        titleFormatter.locale = Locale(identifier: "en_US_POSIX")

        let dateString = dateFormatter.string(from: date)
        let titleString = titleFormatter.string(from: date)
        let durationString = formatDuration(duration)

        return """
        ---
        date: \(dateString)
        duration: \(durationString)
        ---

        # Meeting — \(titleString)


        """
    }

    static func entry(speaker: String, timestamp: TimeInterval, text: String) -> String {
        "**\(speaker)** (\(formatTimestamp(timestamp))): \(text)\n\n"
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// Always 9 characters — `HHhMMmSSs`.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02dh%02dm%02ds", hours, minutes, secs)
    }
}
