import Foundation

public struct AccountRefreshFreshness: Equatable, Sendable {
    public private(set) var lastSuccessfulAt: Date?

    public init(lastSuccessfulAt: Date? = nil) {
        self.lastSuccessfulAt = lastSuccessfulAt
    }

    public mutating func recordSuccess(at date: Date) {
        lastSuccessfulAt = date
    }

    public func failureMessage(
        error: String,
        hasCachedPayload: Bool,
        now: Date
    ) -> String {
        guard hasCachedPayload, let lastSuccessfulAt else { return error }
        return "\(error)正在展示 \(Self.ageText(since: lastSuccessfulAt, now: now))成功读取的暂存数据。"
    }

    public static func ageText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }
}
