import Foundation

public struct ResetCreditNotificationPlan: Equatable, Sendable {
    public let identifier: String
    public let profile: String
    public let title: String
    public let expiry: TimeInterval
    public let fireAt: TimeInterval

    public init(
        identifier: String,
        profile: String,
        title: String,
        expiry: TimeInterval,
        fireAt: TimeInterval
    ) {
        self.identifier = identifier
        self.profile = profile
        self.title = title
        self.expiry = expiry
        self.fireAt = fireAt
    }
}

public enum ResetCreditNotificationPlanner {
    public static let identifierPrefix = "com.hd2yao.codex-profile-switcher.reset-credit."

    public static func plans(
        payload: AccountDashboardPayload,
        now: TimeInterval
    ) -> [ResetCreditNotificationPlan] {
        payload.profiles.flatMap { profile in
            (profile.resetCreditDetails?.credits ?? []).flatMap { card in
                guard card.used != true, let expiry = card.expiresAt, expiry > now else {
                    return [ResetCreditNotificationPlan]()
                }
                return (card.reminders ?? []).compactMap { reminder in
                    guard reminder.at > now else { return nil }
                    return ResetCreditNotificationPlan(
                        identifier: "\(identifierPrefix)\(profile.name).\(Int(expiry)).\(reminder.kind)",
                        profile: profile.name,
                        title: title(kind: reminder.kind),
                        expiry: expiry,
                        fireAt: reminder.at
                    )
                }
            }
        }
        .sorted { lhs, rhs in
            if lhs.fireAt == rhs.fireAt { return lhs.identifier < rhs.identifier }
            return lhs.fireAt < rhs.fireAt
        }
    }

    private static func title(kind: String) -> String {
        switch kind {
        case "previous_workday":
            "重置卡将在下一个工作日到期"
        case "same_day_morning":
            "重置卡今天到期"
        default:
            "重置卡将在 1 小时后到期"
        }
    }
}
