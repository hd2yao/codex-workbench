import CodexWorkbenchCore
import Foundation
@preconcurrency import UserNotifications

final class ResetCreditNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sync(payload: AccountDashboardPayload, now: TimeInterval = Date().timeIntervalSince1970) {
        let plans = ResetCreditNotificationPlanner.plans(payload: payload, now: now)
        let requests = Dictionary(uniqueKeysWithValues: plans.map { ($0.identifier, request(plan: $0)) })
        center.getPendingNotificationRequests { pending in
            let desired = Set(requests.keys)
            let obsolete = pending
                .map(\.identifier)
                .filter {
                    $0.hasPrefix(ResetCreditNotificationPlanner.identifierPrefix)
                        && !desired.contains($0)
                }
            if !obsolete.isEmpty {
                self.center.removePendingNotificationRequests(withIdentifiers: obsolete)
            }
            let existing = Set(pending.map(\.identifier))
            for (identifier, request) in requests where !existing.contains(identifier) {
                self.center.add(request)
            }
        }
    }

    func notifyAutomaticReset(profile: String, outcome: String) {
        let content = UNMutableNotificationContent()
        content.title = outcome == "reset" ? "额度已自动重置" : "重置卡已处理"
        content.body = "已为 \(displayName(profile)) 使用重置卡，并重新读取额度。"
        content.sound = .default
        center.add(
            UNNotificationRequest(
                identifier: "\(ResetCreditNotificationPlanner.identifierPrefix)automatic.\(profile).\(outcome)",
                content: content,
                trigger: nil
            )
        )
    }

    func clearScheduledReminders() {
        center.getPendingNotificationRequests { pending in
            let identifiers = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(ResetCreditNotificationPlanner.identifierPrefix) }
            if !identifiers.isEmpty {
                self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func request(plan: ResetCreditNotificationPlan) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = "\(displayName(plan.profile)) 的重置卡将在 \(expiryText(plan.expiry)) 到期。"
        content.sound = .default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let components = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: plan.fireAt)
        )
        return UNNotificationRequest(
            identifier: plan.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }

    private func displayName(_ profile: String) -> String {
        profile.hasPrefix("hd-") ? String(profile.dropFirst(3)) : profile
    }

    private func expiryText(_ value: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }
}
