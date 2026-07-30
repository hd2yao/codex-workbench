import Foundation

public struct AccountMenuPresentation: Equatable, Sendable {
    public let profile: String?
    public let profileDisplayName: String
    public let quotaText: String
    public let quotaWindowLabel: String
    public let secondaryQuotaText: String
    public let secondaryQuotaWindowLabel: String
    public let resetCreditText: String
    public let runtimeLabel: String
    public let runtimeSymbol: String
    public let accessibilityLabel: String

    public init(
        profile: String?,
        profileDisplayName: String,
        quotaText: String,
        quotaWindowLabel: String,
        secondaryQuotaText: String,
        secondaryQuotaWindowLabel: String,
        resetCreditText: String,
        runtimeLabel: String,
        runtimeSymbol: String,
        accessibilityLabel: String
    ) {
        self.profile = profile
        self.profileDisplayName = profileDisplayName
        self.quotaText = quotaText
        self.quotaWindowLabel = quotaWindowLabel
        self.secondaryQuotaText = secondaryQuotaText
        self.secondaryQuotaWindowLabel = secondaryQuotaWindowLabel
        self.resetCreditText = resetCreditText
        self.runtimeLabel = runtimeLabel
        self.runtimeSymbol = runtimeSymbol
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct AccountRuntimePresentation: Equatable, Sendable {
    public let state: String
    public let label: String
    public let detail: String
    public let symbol: String

    public init(state: String, label: String, detail: String, symbol: String) {
        self.state = state
        self.label = label
        self.detail = detail
        self.symbol = symbol
    }
}

public struct AccountStoragePresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let canMigrateLegacyProfiles: Bool

    public init(
        title: String,
        detail: String,
        canMigrateLegacyProfiles: Bool
    ) {
        self.title = title
        self.detail = detail
        self.canMigrateLegacyProfiles = canMigrateLegacyProfiles
    }
}

public struct AccountRoleRowPresentation: Equatable, Sendable {
    public let title: String
    public let profileDisplayName: String
    public let source: String
    public let confidence: AccountRoleConfidence

    public init(
        title: String,
        profileDisplayName: String,
        source: String,
        confidence: AccountRoleConfidence
    ) {
        self.title = title
        self.profileDisplayName = profileDisplayName
        self.source = source
        self.confidence = confidence
    }
}

public struct AccountRolesPresentation: Equatable, Sendable {
    public let desktop: AccountRoleRowPresentation
    public let task: AccountRoleRowPresentation
    public let attribution: AccountRoleRowPresentation

    public init(
        desktop: AccountRoleRowPresentation,
        task: AccountRoleRowPresentation,
        attribution: AccountRoleRowPresentation
    ) {
        self.desktop = desktop
        self.task = task
        self.attribution = attribution
    }
}

public struct AccountDetailsPresentation: Equatable, Sendable {
    public let currentProfile: AccountProfile?
    public let otherProfiles: [AccountProfile]
    public let currentResetCards: [AccountResetCreditCard]

    public init(
        currentProfile: AccountProfile?,
        otherProfiles: [AccountProfile],
        currentResetCards: [AccountResetCreditCard]
    ) {
        self.currentProfile = currentProfile
        self.otherProfiles = otherProfiles
        self.currentResetCards = currentResetCards
    }
}

public struct WorkspaceInsightsPresentation: Equatable, Sendable {
    public let projectsAvailable: Bool
    public let toolsAvailable: Bool
    public let skillsAvailable: Bool
    public let projects: [AccountProjectRankingItem]
    public let tools: [AccountToolRankingItem]
    public let skills: [AccountSkillRankingItem]

    public init(
        projectsAvailable: Bool,
        toolsAvailable: Bool,
        skillsAvailable: Bool,
        projects: [AccountProjectRankingItem],
        tools: [AccountToolRankingItem],
        skills: [AccountSkillRankingItem]
    ) {
        self.projectsAvailable = projectsAvailable
        self.toolsAvailable = toolsAvailable
        self.skillsAvailable = skillsAvailable
        self.projects = projects
        self.tools = tools
        self.skills = skills
    }
}

public enum AccountPresentationBuilder {
    public static func storage(
        payload: AccountDashboardPayload?
    ) -> AccountStoragePresentation {
        guard let payload else {
            return AccountStoragePresentation(
                title: "账号存储未知",
                detail: "尚未读取账号目录状态。",
                canMigrateLegacyProfiles: false
            )
        }
        switch payload.accountStorage.mode {
        case .unifiedVault:
            return AccountStoragePresentation(
                title: "统一账号库",
                detail: "\(payload.accountStorage.accountCount) 个账号保存在 Codex Home；Vault 快照只读，自动额度消费已暂停。",
                canMigrateLegacyProfiles: false
            )
        case .legacyProfiles:
            return AccountStoragePresentation(
                title: "旧 Profiles 兼容模式",
                detail: "已识别 \(payload.legacyMigration.profileCount) 个旧 Profile；迁移只会在你明确确认后执行。",
                canMigrateLegacyProfiles: payload.legacyMigration.available
                    && payload.legacyMigration.status != "completed"
            )
        case .localDefault:
            return AccountStoragePresentation(
                title: "本机默认账号",
                detail: "当前只识别 Codex Home 中的官方登录状态。",
                canMigrateLegacyProfiles: false
            )
        case .unavailable:
            return AccountStoragePresentation(
                title: "账号存储不可用",
                detail: "未找到可验证的官方登录或账号库。",
                canMigrateLegacyProfiles: false
            )
        }
    }

    public static func confirmedCurrentProfileName(payload: AccountDashboardPayload?) -> String? {
        guard let payload else { return nil }
        switch payload.accountMode {
        case .localDefault:
            guard
                payload.activeProfile == "local-default",
                payload.profiles.contains(where: {
                    $0.name == "local-default"
                        && $0.auth == "present"
                        && $0.account?.available == true
                })
            else {
                return nil
            }
            return "local-default"
        case .managedProfiles:
            guard
                let desktopStatus = payload.desktopStatus,
                desktopStatus.running,
                desktopStatus.managed,
                let activeProfile = payload.activeProfile,
                desktopStatus.activeProfile == activeProfile
            else {
                return nil
            }
            return activeProfile
        case .unavailable:
            return nil
        }
    }

    public static func menu(payload: AccountDashboardPayload?) -> AccountMenuPresentation {
        let profileName = confirmedCurrentProfileName(payload: payload)
        let profile = payload?.profiles.first { $0.name == profileName }
        let window = profile?.rateLimits.primary
        let secondaryWindow = profile?.rateLimits.secondary
        let quotaText = window?.remainingPercent.map(formatPercent) ?? "--"
        let quotaWindowLabel = windowLabel(minutes: window?.windowMinutes)
        let secondaryQuotaText = secondaryWindow?.remainingPercent.map(formatPercent) ?? "--"
        let secondaryQuotaWindowLabel = windowLabel(minutes: secondaryWindow?.windowMinutes)
        let resetCreditText = (
            profile?.resetCreditDetails?.availableCount
                ?? profile?.rateLimits.resetCredits?.availableCount
                ?? profile?.rateLimits.creditsAvailable
        ).map(String.init) ?? "--"
        let runtime = runtime(status: payload?.runtimeStatus)
        let accountText = profileName.map {
            $0 == "local-default" ? "官方登录账号 本机当前账号" : "预期桌面默认账号 \($0)"
        } ?? "桌面默认账号未知"
        let quotaDescription = window?.remainingPercent == nil
            ? "额度未知"
            : "\(quotaWindowLabel) \(quotaText)"

        return AccountMenuPresentation(
            profile: profileName,
            profileDisplayName: profileDisplayName(profileName),
            quotaText: quotaText,
            quotaWindowLabel: quotaWindowLabel,
            secondaryQuotaText: secondaryQuotaText,
            secondaryQuotaWindowLabel: secondaryQuotaWindowLabel,
            resetCreditText: resetCreditText,
            runtimeLabel: runtime.label,
            runtimeSymbol: runtime.symbol,
            accessibilityLabel: "\(accountText)，\(quotaDescription)，Codex \(runtime.label)"
        )
    }

    public static func profileDisplayName(_ profile: String?) -> String {
        guard let profile else { return "未知账号" }
        if profile == "local-default" { return "本机当前账号" }
        return profile.hasPrefix("hd-") ? String(profile.dropFirst(3)) : profile
    }

    public static func roles(
        payload: AccountDashboardPayload?
    ) -> AccountRolesPresentation {
        AccountRolesPresentation(
            desktop: roleRow(
                title: "预期桌面默认账号",
                role: payload?.profileRoles?.desktop
            ),
            task: roleRow(
                title: "当前任务账号",
                role: payload?.profileRoles?.task
            ),
            attribution: roleRow(
                title: "统计归因",
                role: payload?.profileRoles?.attribution
            )
        )
    }

    public static func quotaTitle(
        profileName: String,
        window: AccountQuotaWindow?,
        fallback: String
    ) -> String {
        let windowName = quotaWindowName(minutes: window?.windowMinutes)
            ?? fallback
        return "\(profileDisplayName(profileName)) · \(windowName)额度"
    }

    public static func usageSourceLabel(_ source: String?) -> String {
        switch source {
        case "account_usage": "官方账号用量"
        case "local", "local_usage": "本地用量"
        case nil, "": "本地与官方数据"
        default: "账号统计"
        }
    }

    public static func quotaWindowName(minutes: Int?) -> String? {
        switch minutes {
        case 300:
            return "5 小时"
        case 10_080:
            return "7 日"
        case let value? where value % (24 * 60) == 0:
            return "\(value / (24 * 60)) 日"
        case let value? where value % 60 == 0:
            return "\(value / 60) 小时"
        case let value?:
            return "\(value) 分钟"
        case nil:
            return nil
        }
    }

    public static func details(payload: AccountDashboardPayload?) -> AccountDetailsPresentation {
        guard let payload else {
            return AccountDetailsPresentation(
                currentProfile: nil,
                otherProfiles: [],
                currentResetCards: []
            )
        }
        let currentName = confirmedCurrentProfileName(payload: payload)
        let currentProfile = payload.profiles.first { $0.name == currentName }
        let otherProfiles = payload.profiles
            .filter { $0.name != currentName && $0.name != "local-default" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let resetCards = (currentProfile?.resetCreditDetails?.credits ?? []).sorted { lhs, rhs in
            let lhsUsed = lhs.used == true
            let rhsUsed = rhs.used == true
            if lhsUsed != rhsUsed { return !lhsUsed }
            return (lhs.expiresAt ?? .greatestFiniteMagnitude)
                < (rhs.expiresAt ?? .greatestFiniteMagnitude)
        }
        return AccountDetailsPresentation(
            currentProfile: currentProfile,
            otherProfiles: otherProfiles,
            currentResetCards: resetCards
        )
    }

    public static func workspaceInsights(
        payload: AccountDashboardPayload?
    ) -> WorkspaceInsightsPresentation {
        WorkspaceInsightsPresentation(
            projectsAvailable: payload?.projectRankings?.available ?? false,
            toolsAvailable: payload?.toolRankings?.available ?? false,
            skillsAvailable: payload?.skillRankings?.available ?? false,
            projects: (payload?.projectRankings?.projects ?? []).sorted { lhs, rhs in
                if lhs.tokensUsed == rhs.tokensUsed { return lhs.name < rhs.name }
                return lhs.tokensUsed > rhs.tokensUsed
            },
            tools: (payload?.toolRankings?.tools ?? []).sorted { lhs, rhs in
                if lhs.callCount == rhs.callCount { return lhs.id < rhs.id }
                return lhs.callCount > rhs.callCount
            },
            skills: (payload?.skillRankings?.skills ?? []).sorted { lhs, rhs in
                if lhs.useCount == rhs.useCount { return lhs.name < rhs.name }
                return lhs.useCount > rhs.useCount
            }
        )
    }

    public static func runtime(status: AccountRuntimeStatus?) -> AccountRuntimePresentation {
        guard let status else {
            return AccountRuntimePresentation(
                state: "unknown",
                label: "未知",
                detail: "尚未读取运行状态",
                symbol: "questionmark.circle"
            )
        }

        switch status.state {
        case "running":
            let detail = status.activeProcessCount > 0
                ? "\(status.activeProcessCount) 个对话进程正在运行"
                : "最近 90 秒内有 Codex 输出"
            return AccountRuntimePresentation(
                state: "running",
                label: "运行中",
                detail: detail,
                symbol: "bolt.circle.fill"
            )
        case "waiting":
            return AccountRuntimePresentation(
                state: "waiting",
                label: "待接手",
                detail: "最近 15 分钟内有活动，可能等你继续",
                symbol: "pause.circle.fill"
            )
        case "idle":
            return AccountRuntimePresentation(
                state: "idle",
                label: "空闲",
                detail: "当前没有运行中的对话",
                symbol: "circle"
            )
        default:
            return AccountRuntimePresentation(
                state: "unknown",
                label: "未知",
                detail: "尚未读取运行状态",
                symbol: "questionmark.circle"
            )
        }
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func roleRow(
        title: String,
        role: AccountRole?
    ) -> AccountRoleRowPresentation {
        AccountRoleRowPresentation(
            title: title,
            profileDisplayName: profileDisplayName(role?.profile),
            source: role?.source ?? "没有可靠来源",
            confidence: role?.confidence ?? .unknown
        )
    }

    private static func windowLabel(minutes: Int?) -> String {
        quotaWindowName(minutes: minutes)?
            .replacingOccurrences(of: " ", with: "")
            .appending("剩余")
            ?? "额度"
    }
}
