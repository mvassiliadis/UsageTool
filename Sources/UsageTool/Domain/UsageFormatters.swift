import Foundation

enum UsageFormatters {
    static func percent(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func currency(_ amount: Decimal, compact: Bool = false, locale: Locale = .current) -> String {
        let number = NSDecimalNumber(decimal: amount)
        let absolute = number.doubleValue.magnitude
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        if compact, absolute >= 10_000 {
            formatter.multiplier = 0.001
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 0
            formatter.positiveSuffix = "k" + (formatter.positiveSuffix ?? "")
            formatter.negativeSuffix = "k" + (formatter.negativeSuffix ?? "")
            return formatter.string(from: number) ?? "—"
        }
        formatter.maximumFractionDigits = absolute < 100 ? 2 : 0
        formatter.minimumFractionDigits = absolute < 100 ? 2 : 0
        return formatter.string(from: number) ?? "$—"
    }

    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    static func relativeAge(since date: Date, now: Date) -> String {
        let value = age(since: date, now: now)
        return value == "just now" ? value : "\(value) ago"
    }

    static func resetCountdown(to date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds < 86_400 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(max(minutes, 1))m"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        return "\(days)d \(hours)h"
    }

    static func resetTime(_ date: Date?, now: Date, locale: Locale = .current) -> String? {
        guard let date, date > now else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(locale))
        }
        if date.timeIntervalSince(now) < 7 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(locale))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    static func absolute(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(locale))
    }
}
