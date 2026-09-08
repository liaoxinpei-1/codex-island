import Foundation

public struct UsageWindow: Equatable, Sendable {
    public let remainingPercent: Int
    public let durationMinutes: Int?
    public let resetsAt: Date?

    init?(_ value: JSONValue) {
        guard let used = value["usedPercent"]?.double else { return nil }
        remainingPercent = Int(max(0, min(100, 100 - used)).rounded(.down))
        durationMinutes = value["windowDurationMins"]?.int.flatMap { $0 > 0 ? $0 : nil }
        resetsAt = value["resetsAt"]?.double.map(Date.init(timeIntervalSince1970:))
    }

    public var periodLabel: String {
        guard let minutes = durationMinutes else { return "当前周期" }
        if minutes == 10080 { return "每周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)天" }
        if minutes % 60 == 0 { return "\(minutes / 60)小时" }
        return "\(minutes)分钟"
    }
}

/// Stores no account identifiers, credits, reset tokens, or authentication material.
public struct UsageSnapshot: Equatable, Sendable {
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public var primary: UsageWindow { windows[0] }

    public init?(response: JSONValue, fetchedAt: Date = Date()) {
        let bucket: JSONValue
        if let mapped = response["rateLimitsByLimitId"]?["codex"] {
            bucket = mapped
        } else if let legacy = response["rateLimits"],
                  legacy["limitId"]?.string == nil || legacy["limitId"]?.string == "codex" {
            bucket = legacy
        } else { return nil }
        let valid = ["primary", "secondary"].compactMap { key in bucket[key].flatMap(UsageWindow.init) }
        guard !valid.isEmpty else { return nil }
        windows = valid
        self.fetchedAt = fetchedAt
    }

    public func label(at date: Date = Date()) -> String? {
        let age = date.timeIntervalSince(fetchedAt)
        guard age >= 0, age <= 120, primary.resetsAt.map({ date < $0 }) ?? true else { return nil }
        return "\(primary.remainingPercent)%"
    }
}
