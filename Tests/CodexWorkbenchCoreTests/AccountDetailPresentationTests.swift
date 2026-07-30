import CodexWorkbenchCore
import Foundation

func runAccountDetailPresentationTests(_ runner: inout TestRunner) {
    let master = AccountProfile(
        name: "hd-master",
        auth: "present",
        config: "present",
        rateLimits: AccountRateLimits(primary: AccountQuotaWindow(remainingPercent: 87)),
        resetCreditDetails: AccountResetCreditDetails(
            availableCount: 2,
            credits: [
                AccountResetCreditCard(id: "later", used: false, expiresAt: 3_000),
                AccountResetCreditCard(id: "used", used: true, expiresAt: 1_500),
                AccountResetCreditCard(id: "earlier", used: false, expiresAt: 2_000),
            ]
        )
    )
    let blackwell = AccountProfile(
        name: "hd-sarah-blackwell",
        auth: "present",
        config: "present",
        rateLimits: AccountRateLimits(primary: AccountQuotaWindow(remainingPercent: 99))
    )
    let role = AccountRole(profile: "hd-sarah-blackwell", source: "recent-task", confidence: .inferred)
    let payload = AccountDashboardPayload(
        generatedAt: Date(timeIntervalSince1970: 1_000),
        activeProfile: "hd-master",
        desktopStatus: AccountDesktopStatus(
            running: true,
            managed: true,
            state: "managed_default_home",
            message: nil,
            activeProfile: "hd-master"
        ),
        profileRoles: AccountProfileRoles(
            task: role,
            desktop: AccountRole(profile: "hd-master", source: "desktop", confidence: .confirmed),
            attribution: role,
            taskMatchesDesktop: false
        ),
        profiles: [blackwell, master]
    )

    let details = AccountPresentationBuilder.details(payload: payload)
    runner.expect(
        details.currentProfile?.name == "hd-master",
        "Account details must use the actual logged-in account, never the recent task role"
    )
    runner.expect(
        details.otherProfiles.map(\.name) == ["hd-sarah-blackwell"],
        "The remaining managed accounts should be offered as switch targets"
    )
    runner.expect(
        details.currentResetCards.map(\.id) == ["earlier", "later", "used"],
        "Available reset cards should be ordered by expiry before used cards"
    )
    let roles = AccountPresentationBuilder.roles(payload: payload)
    runner.expect(
        roles.desktop.profileDisplayName == "master"
            && roles.task.profileDisplayName == "sarah-blackwell"
            && roles.attribution.profileDisplayName == "sarah-blackwell",
        "Desktop, task, and attribution roles should remain independently visible"
    )
    runner.expect(
        AccountPresentationBuilder.quotaTitle(
            profileName: master.name,
            window: master.rateLimits.primary,
            fallback: "主要"
        ) == "master · 主要额度",
        "Quota titles should identify the account that owns the value"
    )

    let unknown = AccountPresentationBuilder.details(payload: nil)
    runner.expect(unknown.currentProfile == nil, "Missing payload must not invent a current account")
    runner.expect(unknown.otherProfiles.isEmpty, "Missing payload must not invent switch targets")

    let inconsistentPayload = AccountDashboardPayload(
        generatedAt: Date(timeIntervalSince1970: 1_001),
        activeProfile: "hd-master",
        desktopStatus: AccountDesktopStatus(
            running: true,
            managed: true,
            state: "managed_default_home",
            message: nil,
            activeProfile: "hd-sarah-blackwell"
        ),
        profileRoles: nil,
        profiles: [blackwell, master]
    )
    let inconsistent = AccountPresentationBuilder.details(payload: inconsistentPayload)
    runner.expect(inconsistent.currentProfile == nil, "Account details must not select a current profile from inconsistent records")
    runner.expect(
        inconsistent.otherProfiles.map(\.name) == ["hd-master", "hd-sarah-blackwell"],
        "Every managed profile should remain available when the current account is unknown"
    )
    let unknownRoles = AccountPresentationBuilder.roles(payload: inconsistentPayload)
    runner.expect(
        unknownRoles.desktop.profileDisplayName == "未知账号"
            && unknownRoles.task.profileDisplayName == "未知账号"
            && unknownRoles.attribution.profileDisplayName == "未知账号",
        "Missing roles must stay unknown instead of falling back to the active account"
    )

    let local = AccountProfile(
        name: "local-default",
        path: "/tmp/.codex",
        auth: "present",
        config: "present",
        rateLimits: AccountRateLimits(primary: AccountQuotaWindow(remainingPercent: 43)),
        account: AccountStatusSummary(available: true, type: "chatgpt")
    )
    let localPayload = AccountDashboardPayload(
        generatedAt: Date(timeIntervalSince1970: 1_002),
        activeProfile: "local-default",
        accountMode: .localDefault,
        desktopStatus: AccountDesktopStatus(
            running: false,
            managed: false,
            state: "local_default",
            message: "使用本机默认 Codex 账号",
            activeProfile: "local-default"
        ),
        profileRoles: nil,
        profiles: [local]
    )
    let localDetails = AccountPresentationBuilder.details(payload: localPayload)
    runner.expect(
        localDetails.currentProfile?.name == "local-default",
        "Explicit local mode should select the synthetic default-home account"
    )
    runner.expect(
        localDetails.otherProfiles.isEmpty,
        "The synthetic default-home account must never become a switch target"
    )
}
