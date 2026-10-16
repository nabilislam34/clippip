import Foundation

/// The short age badge on a clip card: "now", "2m", "3h", "Tue", "Oct 3".
enum RelativeTime {
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f
    }()
    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86400 { return weekday.string(from: date) }
        return monthDay.string(from: date)
    }
}
