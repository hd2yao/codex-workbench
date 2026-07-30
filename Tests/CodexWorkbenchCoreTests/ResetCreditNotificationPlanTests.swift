import CodexWorkbenchCore
import Foundation

func runResetCreditNotificationPlanTests(_ runner: inout TestRunner) {
    let now: TimeInterval = 2_000_000
    let expiry = now + 7_200
    let reminderAt = now + 3_600
    let profile = AccountProfile(
        name: "hd-master",
        auth: "present",
        config: "present",
        rateLimits: AccountRateLimits(),
        resetCreditDetails: AccountResetCreditDetails(
            availableCount: 1,
            credits: [
                AccountResetCreditCard(
                    id: "available",
                    used: false,
                    expiresAt: expiry,
                    reminders: [
                        AccountResetCreditReminder(kind: "one_hour", at: reminderAt),
                        AccountResetCreditReminder(kind: "past", at: now - 1),
                    ]
                ),
                AccountResetCreditCard(
                    id: "used",
                    used: true,
                    expiresAt: expiry,
                    reminders: [AccountResetCreditReminder(kind: "one_hour", at: reminderAt)]
                ),
            ],
            earliestExpiresAt: expiry
        )
    )
    let payload = AccountDashboardPayload(
        generatedAt: Date(timeIntervalSince1970: now),
        activeProfile: "hd-master",
        desktopStatus: nil,
        profileRoles: nil,
        profiles: [profile]
    )

    let plans = ResetCreditNotificationPlanner.plans(payload: payload, now: now)
    runner.expect(plans.count == 1, "Only a future reminder for an unused, unexpired card should be scheduled")
    runner.expect(
        plans.first?.identifier
            == "com.hd2yao.codex-profile-switcher.reset-credit.hd-master.2007200.one_hour",
        "Notification identifiers must remain compatible with the legacy app"
    )
    runner.expect(plans.first?.title == "重置卡将在 1 小时后到期", "Reminder kind should map to the old title")
    runner.expect(plans.first?.profile == "hd-master", "Reminder plan should retain the account")
    runner.expect(plans.first?.expiry == expiry, "Reminder plan should retain the card expiry")
    runner.expect(plans.first?.fireAt == reminderAt, "Reminder plan should retain the scheduled time")
}
