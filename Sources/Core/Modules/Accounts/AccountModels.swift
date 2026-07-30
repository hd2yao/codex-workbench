import Foundation

public enum AccountRoleConfidence: String, Codable, Sendable {
    case confirmed
    case inferred
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public struct AccountRole: Codable, Equatable, Sendable {
    public let profile: String?
    public let source: String
    public let confidence: AccountRoleConfidence
    public let observedAt: TimeInterval?
    private let threadId: String?

    public var threadID: String? { threadId }

    public init(
        profile: String?,
        source: String,
        confidence: AccountRoleConfidence,
        observedAt: TimeInterval? = nil,
        threadID: String? = nil
    ) {
        self.profile = profile
        self.source = source
        self.confidence = confidence
        self.observedAt = observedAt
        self.threadId = threadID
    }
}

public struct AccountProfileRoles: Codable, Equatable, Sendable {
    public let task: AccountRole
    public let desktop: AccountRole
    public let attribution: AccountRole
    public let taskMatchesDesktop: Bool?

    public init(
        task: AccountRole,
        desktop: AccountRole,
        attribution: AccountRole,
        taskMatchesDesktop: Bool?
    ) {
        self.task = task
        self.desktop = desktop
        self.attribution = attribution
        self.taskMatchesDesktop = taskMatchesDesktop
    }
}

public struct AccountDesktopStatus: Codable, Equatable, Sendable {
    public let running: Bool
    public let managed: Bool
    public let state: String
    public let message: String?
    public let activeProfile: String?

    public init(running: Bool, managed: Bool, state: String, message: String?, activeProfile: String?) {
        self.running = running
        self.managed = managed
        self.state = state
        self.message = message
        self.activeProfile = activeProfile
    }
}

public struct AccountRuntimeStatus: Codable, Equatable, Sendable {
    public let state: String
    public let light: String
    public let label: String
    public let activeProcessCount: Int
    public let recentProcessCount: Int
    public let latestActivityAgeMs: Int?

    public init(
        state: String,
        light: String,
        label: String,
        activeProcessCount: Int,
        recentProcessCount: Int,
        latestActivityAgeMs: Int? = nil
    ) {
        self.state = state
        self.light = light
        self.label = label
        self.activeProcessCount = activeProcessCount
        self.recentProcessCount = recentProcessCount
        self.latestActivityAgeMs = latestActivityAgeMs
    }
}

public struct AccountAttributionSummary: Codable, Equatable, Sendable {
    public let activeProfile: String?
    public let managed: Bool?

    public init(activeProfile: String? = nil, managed: Bool? = nil) {
        self.activeProfile = activeProfile
        self.managed = managed
    }
}

public struct AccountTokenUsageTotals: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
}

public struct AccountTokenUsageByDate: Codable, Equatable, Sendable {
    public let date: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
}

public struct AccountTokenUsageByModel: Codable, Equatable, Sendable {
    public let model: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
}

public struct AccountLocalTokenSnapshot: Codable, Equatable, Sendable {
    public let eventCount: Int
    public let latestTimestamp: String?
    public let total: AccountTokenUsageTotals
    public let daily: [AccountTokenUsageByDate]?
    public let byModel: [AccountTokenUsageByModel]?
}

public struct AccountStatusSummary: Codable, Equatable, Sendable {
    public let available: Bool?
    public let type: String?
    public let planType: String?
    public let emailPresent: Bool?
    public let requiresOpenAIAuth: Bool?

    public init(
        available: Bool? = nil,
        type: String? = nil,
        planType: String? = nil,
        emailPresent: Bool? = nil,
        requiresOpenAIAuth: Bool? = nil
    ) {
        self.available = available
        self.type = type
        self.planType = planType
        self.emailPresent = emailPresent
        self.requiresOpenAIAuth = requiresOpenAIAuth
    }
}

public struct AccountQuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let remainingPercent: Double?
    public let windowMinutes: Int?
    public let resetsAt: TimeInterval?

    public init(
        usedPercent: Double? = nil,
        remainingPercent: Double? = nil,
        windowMinutes: Int? = nil,
        resetsAt: TimeInterval? = nil
    ) {
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var resetsAtDate: Date? {
        resetsAt.map(Date.init(timeIntervalSince1970:))
    }
}

public struct AccountResetCredits: Codable, Equatable, Sendable {
    public let available: Bool?
    public let availableCount: Int?
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let expiresAt: TimeInterval?

    public init(
        available: Bool? = nil,
        availableCount: Int? = nil,
        hasCredits: Bool? = nil,
        unlimited: Bool? = nil,
        expiresAt: TimeInterval? = nil
    ) {
        self.available = available
        self.availableCount = availableCount
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.expiresAt = expiresAt
    }
}

public struct AccountRateLimits: Codable, Equatable, Sendable {
    public let planType: String?
    public let limitName: String?
    public let creditsAvailable: Int?
    public let primary: AccountQuotaWindow?
    public let secondary: AccountQuotaWindow?
    private let rateLimitReachedType: String?
    public let resetCredits: AccountResetCredits?

    public var reachedType: String? { rateLimitReachedType }

    public init(
        planType: String? = nil,
        limitName: String? = nil,
        creditsAvailable: Int? = nil,
        primary: AccountQuotaWindow? = nil,
        secondary: AccountQuotaWindow? = nil,
        reachedType: String? = nil,
        resetCredits: AccountResetCredits? = nil
    ) {
        self.planType = planType
        self.limitName = limitName
        self.creditsAvailable = creditsAvailable
        self.primary = primary
        self.secondary = secondary
        self.rateLimitReachedType = reachedType
        self.resetCredits = resetCredits
    }
}

public struct AccountResetCreditConsumeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let outcome: String?
    public let expiresAt: TimeInterval?
    public let error: String?

    public static func decode(data: Data) throws -> AccountResetCreditConsumeResult {
        try LedgerRepository.decoder().decode(AccountResetCreditConsumeResult.self, from: data)
    }
}

public struct AccountResetCreditReminder: Codable, Equatable, Sendable {
    public let kind: String
    public let at: TimeInterval

    public init(kind: String, at: TimeInterval) {
        self.kind = kind
        self.at = at
    }
}

public struct AccountResetCreditCard: Codable, Equatable, Sendable {
    public let id: String?
    public let status: String?
    public let used: Bool?
    public let resetType: String?
    public let title: String?
    public let description: String?
    public let grantedAt: TimeInterval?
    public let expiresAt: TimeInterval?
    public let reminders: [AccountResetCreditReminder]?

    public init(
        id: String? = nil,
        status: String? = nil,
        used: Bool? = nil,
        resetType: String? = nil,
        title: String? = nil,
        description: String? = nil,
        grantedAt: TimeInterval? = nil,
        expiresAt: TimeInterval? = nil,
        reminders: [AccountResetCreditReminder]? = nil
    ) {
        self.id = id
        self.status = status
        self.used = used
        self.resetType = resetType
        self.title = title
        self.description = description
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.reminders = reminders
    }

    public var stableID: String {
        id ?? "expiry-\(expiresAt ?? 0)-\(grantedAt ?? 0)"
    }
}

public struct AccountResetCreditDetails: Codable, Equatable, Sendable {
    public let available: Bool?
    public let availableCount: Int?
    public let totalEarnedCount: Int?
    public let credits: [AccountResetCreditCard]
    public let earliestExpiresAt: TimeInterval?
    public let nextExpirationAt: TimeInterval?

    public init(
        available: Bool? = nil,
        availableCount: Int? = nil,
        totalEarnedCount: Int? = nil,
        credits: [AccountResetCreditCard] = [],
        earliestExpiresAt: TimeInterval? = nil,
        nextExpirationAt: TimeInterval? = nil
    ) {
        self.available = available
        self.availableCount = availableCount
        self.totalEarnedCount = totalEarnedCount
        self.credits = credits
        self.earliestExpiresAt = earliestExpiresAt
        self.nextExpirationAt = nextExpirationAt
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case availableCount
        case totalEarnedCount
        case credits
        case earliestExpiresAt
        case nextExpirationAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decodeIfPresent(Bool.self, forKey: .available)
        availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount)
        totalEarnedCount = try container.decodeIfPresent(Int.self, forKey: .totalEarnedCount)
        credits = try container.decodeIfPresent([AccountResetCreditCard].self, forKey: .credits) ?? []
        earliestExpiresAt = try container.decodeIfPresent(TimeInterval.self, forKey: .earliestExpiresAt)
        nextExpirationAt = try container.decodeIfPresent(TimeInterval.self, forKey: .nextExpirationAt)
    }
}

public struct AccountUsageSummary: Codable, Equatable, Sendable {
    public let lifetimeTokens: Int?
    public let peakDailyTokens: Int?
    public let longestRunningTurnSec: Int?
    public let currentStreakDays: Int?
    public let longestStreakDays: Int?
}

public struct AccountDailyUsageBucket: Codable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int
}

public struct AccountUsage: Codable, Equatable, Sendable {
    public let summary: AccountUsageSummary?
    public let dailyUsageBuckets: [AccountDailyUsageBucket]?
}

public struct AccountUsageMetrics: Codable, Equatable, Sendable {
    public let todayTokens: Int?
    public let todayAvailable: Bool?
    public let last7Tokens: Int?
    public let last14Tokens: Int?
    public let latestDate: String?
    public let source: String?
}

public struct AccountAttributionAccuracy: Codable, Equatable, Sendable {
    public let date: String
    public let estimatedTokens: Int
    public let officialTokens: Int
    public let deltaTokens: Int
    public let deltaPercent: Double?
}

public struct AccountTokenAttribution: Codable, Equatable, Sendable {
    public let activeProfile: String?
    public let managed: Bool
    public let estimateAvailable: Bool
    public let todayEstimatedTokens: Int?
    public let todayOfficialTokens: Int?
    public let todayDisplayTokens: Int?
    public let todaySource: String?
    public let previousDayAccuracy: AccountAttributionAccuracy?
}

public struct AccountThreadTokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let nonCachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        nonCachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.nonCachedInputTokens = nonCachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        nonCachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .nonCachedInputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case cachedInputTokens
        case nonCachedInputTokens
        case outputTokens
        case reasoningOutputTokens
        case totalTokens
    }
}

public struct AccountThreadAttributionChild: Codable, Equatable, Sendable, Identifiable {
    private let threadId: String
    public var threadID: String { threadId }
    public var id: String { threadID }
    public let relation: String
    public let depth: Int
    public let metadataStatus: String
    public let tokens: AccountThreadTokenUsage
    public let rolloutCount: Int

    public init(
        threadID: String,
        relation: String,
        depth: Int,
        metadataStatus: String,
        tokens: AccountThreadTokenUsage,
        rolloutCount: Int
    ) {
        self.threadId = threadID
        self.relation = relation
        self.depth = depth
        self.metadataStatus = metadataStatus
        self.tokens = tokens
        self.rolloutCount = rolloutCount
    }

}

public struct AccountThreadAttributionTask: Codable, Equatable, Sendable, Identifiable {
    private let threadId: String
    public var threadID: String { threadId }
    public var id: String { threadID }
    public let status: String
    public let statusLabel: String
    public let ownTokens: AccountThreadTokenUsage
    public let childTokens: AccountThreadTokenUsage
    public let mergedTokens: AccountThreadTokenUsage
    public let childTaskCount: Int
    public let forkChildCount: Int
    public let childShare: Double
    public let childShareAbnormal: Bool
    public let fullContextForkRisk: Bool
    public let riskMessages: [String]
    public let children: [AccountThreadAttributionChild]
    public let rolloutCount: Int

    public init(
        threadID: String,
        status: String,
        statusLabel: String,
        ownTokens: AccountThreadTokenUsage,
        childTokens: AccountThreadTokenUsage,
        mergedTokens: AccountThreadTokenUsage,
        childTaskCount: Int,
        forkChildCount: Int,
        childShare: Double,
        childShareAbnormal: Bool,
        fullContextForkRisk: Bool,
        riskMessages: [String],
        children: [AccountThreadAttributionChild],
        rolloutCount: Int
    ) {
        self.threadId = threadID
        self.status = status
        self.statusLabel = statusLabel
        self.ownTokens = ownTokens
        self.childTokens = childTokens
        self.mergedTokens = mergedTokens
        self.childTaskCount = childTaskCount
        self.forkChildCount = forkChildCount
        self.childShare = childShare
        self.childShareAbnormal = childShareAbnormal
        self.fullContextForkRisk = fullContextForkRisk
        self.riskMessages = riskMessages
        self.children = children
        self.rolloutCount = rolloutCount
    }

}

public struct AccountThreadAttributionRiskCounts: Codable, Equatable, Sendable {
    public let childShare: Int
    public let fullContextFork: Int
    public let dataQuality: Int

    public init(childShare: Int = 0, fullContextFork: Int = 0, dataQuality: Int = 0) {
        self.childShare = childShare
        self.fullContextFork = fullContextFork
        self.dataQuality = dataQuality
    }
}

public struct AccountThreadAttributionSummary: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: String
    public let scopeLabel: String
    public let disclaimer: String
    public let isOfficialBilling: Bool
    public let generatedAt: Date?
    public let rolloutCount: Int
    public let topLevelTaskCount: Int
    public let metadataMissingCount: Int
    public let metadataMalformedCount: Int
    public let badLineCount: Int
    public let riskCounts: AccountThreadAttributionRiskCounts
    public let tasks: [AccountThreadAttributionTask]

    public init(
        schemaVersion: Int = 1,
        source: String = "local_rollouts",
        scopeLabel: String = "本机 rollout 统计",
        disclaimer: String = "不是官方账单，也不是实时配额。",
        isOfficialBilling: Bool = false,
        generatedAt: Date? = nil,
        rolloutCount: Int = 0,
        topLevelTaskCount: Int = 0,
        metadataMissingCount: Int = 0,
        metadataMalformedCount: Int = 0,
        badLineCount: Int = 0,
        riskCounts: AccountThreadAttributionRiskCounts = AccountThreadAttributionRiskCounts(),
        tasks: [AccountThreadAttributionTask] = []
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.scopeLabel = scopeLabel
        self.disclaimer = disclaimer
        self.isOfficialBilling = isOfficialBilling
        self.generatedAt = generatedAt
        self.rolloutCount = rolloutCount
        self.topLevelTaskCount = topLevelTaskCount
        self.metadataMissingCount = metadataMissingCount
        self.metadataMalformedCount = metadataMalformedCount
        self.badLineCount = badLineCount
        self.riskCounts = riskCounts
        self.tasks = tasks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "local_rollouts"
        scopeLabel = try container.decodeIfPresent(String.self, forKey: .scopeLabel) ?? "本机 rollout 统计"
        disclaimer = try container.decodeIfPresent(String.self, forKey: .disclaimer)
            ?? "不是官方账单，也不是实时配额。"
        isOfficialBilling = try container.decodeIfPresent(Bool.self, forKey: .isOfficialBilling) ?? false
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
        rolloutCount = try container.decodeIfPresent(Int.self, forKey: .rolloutCount) ?? 0
        topLevelTaskCount = try container.decodeIfPresent(Int.self, forKey: .topLevelTaskCount) ?? 0
        metadataMissingCount = try container.decodeIfPresent(Int.self, forKey: .metadataMissingCount) ?? 0
        metadataMalformedCount = try container.decodeIfPresent(Int.self, forKey: .metadataMalformedCount) ?? 0
        badLineCount = try container.decodeIfPresent(Int.self, forKey: .badLineCount) ?? 0
        riskCounts = try container.decodeIfPresent(
            AccountThreadAttributionRiskCounts.self,
            forKey: .riskCounts
        ) ?? AccountThreadAttributionRiskCounts()
        tasks = try container.decodeIfPresent(
            [AccountThreadAttributionTask].self,
            forKey: .tasks
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case source
        case scopeLabel
        case disclaimer
        case isOfficialBilling
        case generatedAt
        case rolloutCount
        case topLevelTaskCount
        case metadataMissingCount
        case metadataMalformedCount
        case badLineCount
        case riskCounts
        case tasks
    }
}

public struct AccountManagedProjects: Codable, Equatable, Sendable {
    public let generatedAt: Date?
    public let projects: [AccountManagedProject]
    public let discoveredServices: [AccountDiscoveredService]
    public let codexTasks: [AccountCodexTask]
    public let browserProcesses: [AccountBrowserProcess]
    public let errors: AccountManagedProjectErrors?

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case projects
        case discoveredServices
        case codexTasks
        case browserProcesses
        case errors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
        projects = try container.decodeIfPresent([AccountManagedProject].self, forKey: .projects) ?? []
        discoveredServices = try container.decodeIfPresent(
            [AccountDiscoveredService].self,
            forKey: .discoveredServices
        ) ?? []
        codexTasks = try container.decodeIfPresent([AccountCodexTask].self, forKey: .codexTasks) ?? []
        browserProcesses = try container.decodeIfPresent(
            [AccountBrowserProcess].self,
            forKey: .browserProcesses
        ) ?? []
        errors = try container.decodeIfPresent(AccountManagedProjectErrors.self, forKey: .errors)
    }
}

public struct AccountManagedProject: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let cwd: String
    public let command: String
    public let port: Int?
    public let pid: Int?
    public let pgid: Int?
    public let startedAtMs: Int64?
    public let stopRequestedAtMs: Int64?
    public let lastError: String?
    public let state: String
    public let stateLabel: String
    public let canStart: Bool
    public let canStop: Bool
    public let canSwitch: Bool?
    public let canRemove: Bool?
    public let canOpen: Bool?
    public let reason: String?
    public let actionHint: String?
    public let serviceURL: String?
    public let serviceKind: String?
    public let portListening: Bool
    public let portOwnerPid: Int?
    public let portOwnerCommand: String?
}

public struct AccountDiscoveredService: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let source: String
    public let sourceTaskIds: [String]
    public let cwd: String
    public let command: String
    public let port: Int
    public let state: String
    public let stateLabel: String
    public let portListening: Bool
    public let portOwnerPid: Int?
    public let portOwnerCommand: String?
    public let canRegister: Bool
    public let reason: String
    public let actionHint: String?
    public let canOpen: Bool?
    public let serviceURL: String?
    public let serviceKind: String?
    public let lastSeenAtMs: Int64?
}

public struct AccountCodexTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let taskId: String
    public let cwd: String?
    public let command: String
    public let pid: Int?
    public let state: String
    public let stateLabel: String
    public let kind: String
    public let relatedPorts: [Int]
    public let portOwnerPid: Int?
    public let updatedAtMs: Int64?
    public let canStop: Bool
}

public struct AccountBrowserProcess: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let taskLabel: String?
    public let pid: Int
    public let state: String
    public let stateLabel: String
    public let kind: String
    public let command: String
    public let canStop: Bool
    public let fingerprint: String?
}

public struct AccountManagedProjectErrors: Codable, Equatable, Sendable {
    public let processes: String?
    public let ports: String?
}

public struct AccountProjectRankingItem: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let threadCount: Int
    public let tokensUsed: Int
    public let latestUpdatedAt: Int
}

public struct AccountProjectRankings: Codable, Equatable, Sendable {
    public let available: Bool
    public let projects: [AccountProjectRankingItem]
}

public struct AccountToolRankingItem: Codable, Equatable, Sendable {
    public let id: String
    public let namespace: String
    public let name: String
    public let callCount: Int
    public let latestUpdatedAt: Int
    public let threadTokens: Int
}

public struct AccountToolRankings: Codable, Equatable, Sendable {
    public let available: Bool
    public let tools: [AccountToolRankingItem]
}

public struct AccountSkillRankingItem: Codable, Equatable, Sendable {
    public let name: String
    public let useCount: Int
    public let latestTimestamp: String?
}

public struct AccountSkillRankings: Codable, Equatable, Sendable {
    public let available: Bool
    public let skills: [AccountSkillRankingItem]
    public let badLineCount: Int?
}

public struct AccountProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }

    public let name: String
    public let path: String?
    public let auth: String
    public let config: String
    public let account: AccountStatusSummary?
    public let rateLimits: AccountRateLimits
    public let resetCreditDetails: AccountResetCreditDetails?
    public let resetCreditStale: Bool?
    public let resetCreditError: String?
    public let usage: AccountUsage?
    public let usageMetrics: AccountUsageMetrics?
    public let tokenAttribution: AccountTokenAttribution?
    public let remoteStale: Bool?
    public let remoteError: String?

    public init(
        name: String,
        path: String? = nil,
        auth: String,
        config: String,
        rateLimits: AccountRateLimits,
        resetCreditDetails: AccountResetCreditDetails? = nil,
        remoteStale: Bool? = nil,
        remoteError: String? = nil,
        account: AccountStatusSummary? = nil,
        resetCreditStale: Bool? = nil,
        resetCreditError: String? = nil,
        usage: AccountUsage? = nil,
        usageMetrics: AccountUsageMetrics? = nil,
        tokenAttribution: AccountTokenAttribution? = nil
    ) {
        self.name = name
        self.path = path
        self.auth = auth
        self.config = config
        self.account = account
        self.rateLimits = rateLimits
        self.resetCreditDetails = resetCreditDetails
        self.resetCreditStale = resetCreditStale
        self.resetCreditError = resetCreditError
        self.usage = usage
        self.usageMetrics = usageMetrics
        self.tokenAttribution = tokenAttribution
        self.remoteStale = remoteStale
        self.remoteError = remoteError
    }
}

public enum AccountMode: String, Codable, Equatable, Sendable {
    case managedProfiles = "managed_profiles"
    case localDefault = "local_default"
    case unavailable

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unavailable
    }
}

public enum AccountStorageMode: String, Codable, Equatable, Sendable {
    case unifiedVault = "unified_vault"
    case legacyProfiles = "legacy_profiles"
    case localDefault = "local_default"
    case unavailable

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unavailable
    }
}

public struct AccountStorageStatus: Codable, Equatable, Sendable {
    public let mode: AccountStorageMode
    private let activeAccountId: String?
    public let accountCount: Int
    public let rootAuthKind: String

    public var activeAccountID: String? { activeAccountId }

    public init(
        mode: AccountStorageMode,
        activeAccountID: String?,
        accountCount: Int,
        rootAuthKind: String
    ) {
        self.mode = mode
        self.activeAccountId = activeAccountID
        self.accountCount = max(0, accountCount)
        self.rootAuthKind = rootAuthKind
    }
}

public struct AccountLegacyMigrationStatus: Codable, Equatable, Sendable {
    public let available: Bool
    public let profileCount: Int
    public let status: String
    public let requiresConfirmation: Bool

    public init(
        available: Bool,
        profileCount: Int,
        status: String,
        requiresConfirmation: Bool
    ) {
        self.available = available
        self.profileCount = max(0, profileCount)
        self.status = status
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct AccountLegacyMigrationReport: Codable, Equatable, Sendable {
    public let dryRun: Bool
    public let profileCount: Int
    public let plannedImportCount: Int
    public let importedCount: Int
    public let deduplicatedProfiles: [String]
    public let legacyProfilesPreserved: Bool
}

public struct AccountDashboardPayload: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let activeProfile: String?
    public let accountMode: AccountMode
    public let accountStorage: AccountStorageStatus
    public let legacyMigration: AccountLegacyMigrationStatus
    public let runtimeStatus: AccountRuntimeStatus?
    public let desktopStatus: AccountDesktopStatus?
    public let profileRoles: AccountProfileRoles?
    public let attributionSummary: AccountAttributionSummary?
    public let localSnapshot: AccountLocalTokenSnapshot?
    public let threadAttribution: AccountThreadAttributionSummary?
    public let projectRankings: AccountProjectRankings?
    public let toolRankings: AccountToolRankings?
    public let skillRankings: AccountSkillRankings?
    public let managedProjects: AccountManagedProjects?
    public let profiles: [AccountProfile]

    public init(
        generatedAt: Date,
        activeProfile: String?,
        accountMode: AccountMode = .managedProfiles,
        desktopStatus: AccountDesktopStatus?,
        profileRoles: AccountProfileRoles?,
        profiles: [AccountProfile],
        runtimeStatus: AccountRuntimeStatus? = nil,
        attributionSummary: AccountAttributionSummary? = nil,
        localSnapshot: AccountLocalTokenSnapshot? = nil,
        threadAttribution: AccountThreadAttributionSummary? = nil,
        projectRankings: AccountProjectRankings? = nil,
        toolRankings: AccountToolRankings? = nil,
        skillRankings: AccountSkillRankings? = nil,
        managedProjects: AccountManagedProjects? = nil,
        accountStorage: AccountStorageStatus? = nil,
        legacyMigration: AccountLegacyMigrationStatus? = nil
    ) {
        self.generatedAt = generatedAt
        self.activeProfile = activeProfile
        self.accountMode = accountMode
        self.accountStorage = accountStorage ?? Self.inferredStorage(
            mode: accountMode,
            activeProfile: activeProfile,
            profiles: profiles
        )
        self.legacyMigration = legacyMigration ?? Self.inferredMigration(
            storage: self.accountStorage,
            profiles: profiles
        )
        self.runtimeStatus = runtimeStatus
        self.desktopStatus = desktopStatus
        self.profileRoles = profileRoles
        self.attributionSummary = attributionSummary
        self.localSnapshot = localSnapshot
        self.threadAttribution = threadAttribution
        self.projectRankings = projectRankings
        self.toolRankings = toolRankings
        self.skillRankings = skillRankings
        self.managedProjects = managedProjects
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case activeProfile
        case accountMode
        case accountStorage
        case legacyMigration
        case runtimeStatus
        case desktopStatus
        case profileRoles
        case attributionSummary
        case localSnapshot
        case threadAttribution
        case projectRankings
        case toolRankings
        case skillRankings
        case managedProjects
        case profiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        activeProfile = try container.decodeIfPresent(String.self, forKey: .activeProfile)
        accountMode = try container.decodeIfPresent(AccountMode.self, forKey: .accountMode)
            ?? .managedProfiles
        let decodedProfiles = try container.decode([AccountProfile].self, forKey: .profiles)
        profiles = decodedProfiles
        accountStorage = try container.decodeIfPresent(
            AccountStorageStatus.self,
            forKey: .accountStorage
        ) ?? Self.inferredStorage(
            mode: accountMode,
            activeProfile: activeProfile,
            profiles: decodedProfiles
        )
        legacyMigration = try container.decodeIfPresent(
            AccountLegacyMigrationStatus.self,
            forKey: .legacyMigration
        ) ?? Self.inferredMigration(
            storage: accountStorage,
            profiles: decodedProfiles
        )
        runtimeStatus = try container.decodeIfPresent(AccountRuntimeStatus.self, forKey: .runtimeStatus)
        desktopStatus = try container.decodeIfPresent(AccountDesktopStatus.self, forKey: .desktopStatus)
        profileRoles = try container.decodeIfPresent(AccountProfileRoles.self, forKey: .profileRoles)
        attributionSummary = try container.decodeIfPresent(
            AccountAttributionSummary.self,
            forKey: .attributionSummary
        )
        localSnapshot = try container.decodeIfPresent(
            AccountLocalTokenSnapshot.self,
            forKey: .localSnapshot
        )
        threadAttribution = try? container.decode(
            AccountThreadAttributionSummary.self,
            forKey: .threadAttribution
        )
        projectRankings = try container.decodeIfPresent(
            AccountProjectRankings.self,
            forKey: .projectRankings
        )
        toolRankings = try container.decodeIfPresent(
            AccountToolRankings.self,
            forKey: .toolRankings
        )
        skillRankings = try container.decodeIfPresent(
            AccountSkillRankings.self,
            forKey: .skillRankings
        )
        managedProjects = try container.decodeIfPresent(
            AccountManagedProjects.self,
            forKey: .managedProjects
        )
    }

    private static func inferredStorage(
        mode: AccountMode,
        activeProfile: String?,
        profiles: [AccountProfile]
    ) -> AccountStorageStatus {
        let storageMode: AccountStorageMode
        switch mode {
        case .managedProfiles: storageMode = .legacyProfiles
        case .localDefault: storageMode = .localDefault
        case .unavailable: storageMode = .unavailable
        }
        return AccountStorageStatus(
            mode: storageMode,
            activeAccountID: activeProfile,
            accountCount: profiles.count,
            rootAuthKind: storageMode == .localDefault ? "plain_file" : "unknown"
        )
    }

    private static func inferredMigration(
        storage: AccountStorageStatus,
        profiles: [AccountProfile]
    ) -> AccountLegacyMigrationStatus {
        let legacy = storage.mode == .legacyProfiles
        return AccountLegacyMigrationStatus(
            available: legacy && !profiles.isEmpty,
            profileCount: legacy ? profiles.count : 0,
            status: legacy && !profiles.isEmpty ? "not_started" : "not_applicable",
            requiresConfirmation: legacy && !profiles.isEmpty
        )
    }

    public static func decode(data: Data) throws -> AccountDashboardPayload {
        try LedgerRepository.decoder().decode(AccountDashboardPayload.self, from: data)
    }
}
