import Foundation

public struct WorkbenchVisualAcceptanceConfiguration: Equatable, Sendable {
    public static let fixtureEnvironmentKey = "CODEX_WORKBENCH_VISUAL_FIXTURE"
    public static let appearanceEnvironmentKey = "CODEX_WORKBENCH_VISUAL_APPEARANCE"
    public static let surfaceEnvironmentKey = "CODEX_WORKBENCH_VISUAL_SURFACE"
    public static let moduleEnvironmentKey = "CODEX_WORKBENCH_VISUAL_MODULE"

    public enum Fixture: String, Equatable, Sendable {
        case ready
        case stale
        case error
        case switching
        case local
        case legacy
        case codexCompatibility = "codex-compatibility"
        case ambiguousClient = "ambiguous-client"
        case projectServices = "project-services"
        case restartConfirmation = "restart-confirmation"
        case restarting
        case restartError = "restart-error"
        case diagnostics
    }

    public enum Appearance: String, Equatable, Sendable {
        case dark
        case light
    }

    public enum Surface: String, Equatable, Sendable {
        case menu
    }

    public let fixture: Fixture?
    public let appearance: Appearance?
    public let surface: Surface?
    public let module: AppModule?

    public init(
        fixture: Fixture?,
        appearance: Appearance?,
        surface: Surface?,
        module: AppModule? = nil
    ) {
        self.fixture = fixture
        self.appearance = appearance
        self.surface = surface
        self.module = module
    }

    public var liveOperationsAllowed: Bool {
        fixture == nil
    }

    public var windowSceneID: String {
        fixture == nil ? "main" : "visual-acceptance"
    }

    public static func parse(environment: [String: String]) -> Self {
        let fixture = environment[fixtureEnvironmentKey].flatMap(Fixture.init(rawValue:))
        return Self(
            fixture: fixture,
            appearance: environment[appearanceEnvironmentKey].flatMap(Appearance.init(rawValue:)),
            surface: fixture.flatMap { _ in
                environment[surfaceEnvironmentKey].flatMap(Surface.init(rawValue:))
            },
            module: fixture.flatMap { _ in
                environment[moduleEnvironmentKey].flatMap(AppModule.init(rawValue:))
            }
        )
    }
}

public enum WorkbenchVisualRestartStage: Equatable, Sendable {
    case preparing
    case quitting
    case launching
    case verifying
}

public enum WorkbenchDataHealthLevel: String, Equatable, Sendable {
    case healthy
    case degraded
    case unavailable
}

public struct WorkbenchDataHealthPresentation: Equatable, Sendable {
    public let level: WorkbenchDataHealthLevel
    public let label: String
    public let detail: String
    public let lastSuccessfulRefresh: Date?

    public init(
        level: WorkbenchDataHealthLevel,
        label: String,
        detail: String,
        lastSuccessfulRefresh: Date?
    ) {
        self.level = level
        self.label = label
        self.detail = detail
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
    }
}

public enum WorkbenchDataHealthBuilder {
    public static func build(
        ledgerWarnings: [String],
        accountPayloadAvailable: Bool,
        accountError: String?,
        lastSuccessfulRefresh: Date?,
        desktopClientStatus: DesktopClientSelectionStatus,
        now: Date = Date()
    ) -> WorkbenchDataHealthPresentation {
        if !accountPayloadAvailable, accountError != nil {
            return WorkbenchDataHealthPresentation(
                level: .unavailable,
                label: "数据源不可用",
                detail: "账号状态无法读取",
                lastSuccessfulRefresh: lastSuccessfulRefresh
            )
        }

        let isStale = lastSuccessfulRefresh.map {
            now.timeIntervalSince($0) > 5 * 60
        } ?? true
        if !ledgerWarnings.isEmpty
            || accountError != nil
            || desktopClientStatus != .selected
            || isStale
        {
            let detail: String
            if desktopClientStatus == .ambiguous {
                detail = "桌面客户端身份有歧义"
            } else if accountError != nil {
                detail = "账号数据已降级"
            } else if !ledgerWarnings.isEmpty {
                detail = "\(ledgerWarnings.count) 个证据读取警告"
            } else {
                detail = "等待新鲜数据"
            }
            return WorkbenchDataHealthPresentation(
                level: .degraded,
                label: "数据源已降级",
                detail: detail,
                lastSuccessfulRefresh: lastSuccessfulRefresh
            )
        }
        return WorkbenchDataHealthPresentation(
            level: .healthy,
            label: "数据源正常",
            detail: "账号、日志与客户端均已核实",
            lastSuccessfulRefresh: lastSuccessfulRefresh
        )
    }
}

public enum WorkbenchStartupPolicy {
    public static func shouldMigrateLoginItem(
        configuration: WorkbenchVisualAcceptanceConfiguration
    ) -> Bool {
        configuration.liveOperationsAllowed
    }
}

public struct WorkbenchVisualAcceptanceSnapshot: Equatable, Sendable {
    public let payload: AccountDashboardPayload?
    public let errorMessage: String?
    public let switchingProfile: String?
    public let lastUpdatedAt: Date
    public let isCodexRunning: Bool
    public let desktopClientSelection: DesktopClientSelectionResult
    public let events: [OperationEvent]
    public let blocksLiveOperations: Bool
    public let banner: String
    public let workspaceCatalog: WorkspaceCatalogPresentation
    public let restartConfirmationReason: AccountRestartConfirmationReason?
    public let restartStage: WorkbenchVisualRestartStage?
    public let presentsDiagnostics: Bool
    public let diagnosticSnapshot: WorkbenchDiagnosticSnapshot

    public static func make(
        for fixture: WorkbenchVisualAcceptanceConfiguration.Fixture,
        now: Date = Date()
    ) -> Self {
        let payload: AccountDashboardPayload?
        switch fixture {
        case .error:
            payload = nil
        case .local:
            payload = sampleLocalPayload(now: now)
        case .legacy:
            payload = samplePayload(now: now, storageMode: .legacyProfiles)
        case .projectServices:
            payload = samplePayload(
                now: now,
                managedProjects: sampleManagedProjects(now: now)
            )
        default:
            payload = samplePayload(now: now)
        }
        let desktopClientSelection = sampleDesktopClientSelection(for: fixture)
        return Self(
            payload: payload,
            errorMessage: errorMessage(for: fixture, now: now),
            switchingProfile: fixture == .switching ? "hd-master" : nil,
            lastUpdatedAt: fixture == .stale ? now.addingTimeInterval(-600) : now,
            isCodexRunning: desktopClientSelection.target?.isRunning == true,
            desktopClientSelection: desktopClientSelection,
            events: sampleEvents(now: now),
            blocksLiveOperations: true,
            banner: "视觉验收模式 · 不执行真实账号操作",
            workspaceCatalog: sampleWorkspaceCatalog(now: now),
            restartConfirmationReason: fixture == .restartConfirmation ? .runningTask : nil,
            restartStage: fixture == .restarting ? .verifying : nil,
            presentsDiagnostics: fixture == .diagnostics
                || fixture == .ambiguousClient,
            diagnosticSnapshot: sampleDiagnosticSnapshot(
                ambiguous: fixture == .ambiguousClient
            )
        )
    }

    private static func errorMessage(
        for fixture: WorkbenchVisualAcceptanceConfiguration.Fixture,
        now: Date
    ) -> String? {
        switch fixture {
        case .stale:
            AccountRefreshFreshness(lastSuccessfulAt: now.addingTimeInterval(-600))
                .failureMessage(
                    error: "账号状态刷新失败。",
                    hasCachedPayload: true,
                    now: now
                )
        case .error:
            "无法读取账号状态；请检查内置账号模块。"
        case .restartError:
            "ChatGPT 重启未完成：检测到同一路径的额外主进程，已停止操作。"
        case .ready, .switching, .local, .legacy, .codexCompatibility,
             .ambiguousClient,
             .projectServices,
             .restartConfirmation, .restarting, .diagnostics:
            nil
        }
    }

    private static func sampleLocalPayload(now: Date) -> AccountDashboardPayload {
        let local = sampleProfile(
            name: "local-default",
            remainingPercent: 64,
            resetCreditCount: 0,
            now: now,
            includeOfficialUsage: false
        )
        return AccountDashboardPayload(
            generatedAt: now,
            activeProfile: local.name,
            accountMode: .localDefault,
            desktopStatus: AccountDesktopStatus(
                running: true,
                managed: false,
                state: "local_default",
                message: "本机当前账号",
                activeProfile: local.name
            ),
            profileRoles: nil,
            profiles: [local],
            runtimeStatus: AccountRuntimeStatus(
                state: "idle",
                light: "red",
                label: "空闲",
                activeProcessCount: 0,
                recentProcessCount: 0
            ),
            localSnapshot: sampleLocalTokenSnapshot(now: now)
        )
    }

    private static func samplePayload(
        now: Date,
        storageMode: AccountStorageMode = .unifiedVault,
        managedProjects: AccountManagedProjects? = nil
    ) -> AccountDashboardPayload {
        let blackwell = sampleProfile(
            name: "hd-sarah-blackwell",
            remainingPercent: 49,
            resetCreditCount: 1,
            now: now
        )
        let master = sampleProfile(
            name: "hd-master",
            remainingPercent: 53,
            resetCreditCount: 2,
            now: now
        )
        let taskRole = AccountRole(
            profile: blackwell.name,
            source: "recent_active_thread_rate_limit_match",
            confidence: .inferred
        )
        let desktopRole = AccountRole(
            profile: blackwell.name,
            source: "vault_state_expected",
            confidence: .inferred
        )
        let attributionRole = AccountRole(
            profile: blackwell.name,
            source: "attribution_ledger",
            confidence: .confirmed
        )
        return AccountDashboardPayload(
            generatedAt: now,
            activeProfile: blackwell.name,
            desktopStatus: AccountDesktopStatus(
                running: true,
                managed: true,
                state: "managed_default_home",
                message: nil,
                activeProfile: blackwell.name
            ),
            profileRoles: AccountProfileRoles(
                task: taskRole,
                desktop: desktopRole,
                attribution: attributionRole,
                taskMatchesDesktop: true
            ),
            profiles: [blackwell, master],
            runtimeStatus: AccountRuntimeStatus(
                state: "running",
                light: "green",
                label: "运行中",
                activeProcessCount: 1,
                recentProcessCount: 1,
                latestActivityAgeMs: 1_200
            ),
            attributionSummary: AccountAttributionSummary(
                activeProfile: blackwell.name,
                managed: true
            ),
            threadAttribution: sampleThreadAttribution(now: now),
            projectRankings: AccountProjectRankings(
                available: true,
                projects: [
                    AccountProjectRankingItem(
                        name: "tools",
                        path: "/Users/example/program/tools",
                        threadCount: 2,
                        tokensUsed: 324_000,
                        latestUpdatedAt: Int(now.addingTimeInterval(-600).timeIntervalSince1970)
                    ),
                ]
            ),
            toolRankings: AccountToolRankings(
                available: true,
                tools: [
                    AccountToolRankingItem(
                        id: "functions.exec_command",
                        namespace: "functions",
                        name: "exec_command",
                        callCount: 18,
                        latestUpdatedAt: Int(now.addingTimeInterval(-900).timeIntervalSince1970),
                        threadTokens: 42_000
                    ),
                ]
            ),
            skillRankings: AccountSkillRankings(
                available: true,
                skills: [
                    AccountSkillRankingItem(
                        name: "executing-plans",
                        useCount: 4,
                        latestTimestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-1_200))
                    ),
                ],
                badLineCount: 0
            ),
            managedProjects: managedProjects,
            accountStorage: AccountStorageStatus(
                mode: storageMode,
                activeAccountID: blackwell.name,
                accountCount: 2,
                rootAuthKind: storageMode == .unifiedVault ? "plain_file" : "symlink"
            ),
            legacyMigration: AccountLegacyMigrationStatus(
                available: storageMode == .legacyProfiles,
                profileCount: storageMode == .legacyProfiles ? 2 : 0,
                status: storageMode == .legacyProfiles ? "not_started" : "not_applicable",
                requiresConfirmation: storageMode == .legacyProfiles
            )
        )
    }

    private static func sampleThreadAttribution(now: Date) -> AccountThreadAttributionSummary {
        let parent = AccountThreadTokenUsage(
            inputTokens: 18_000,
            cachedInputTokens: 10_000,
            nonCachedInputTokens: 8_000,
            outputTokens: 2_000,
            reasoningOutputTokens: 1_200,
            totalTokens: 20_000
        )
        let child = AccountThreadTokenUsage(
            inputTokens: 148_000,
            cachedInputTokens: 126_000,
            nonCachedInputTokens: 22_000,
            outputTokens: 9_000,
            reasoningOutputTokens: 4_000,
            totalTokens: 157_000
        )
        let merged = AccountThreadTokenUsage(
            inputTokens: 166_000,
            cachedInputTokens: 136_000,
            nonCachedInputTokens: 30_000,
            outputTokens: 11_000,
            reasoningOutputTokens: 5_700,
            totalTokens: 177_000
        )
        let directChild = AccountThreadTokenUsage(
            inputTokens: 84_000,
            cachedInputTokens: 66_000,
            nonCachedInputTokens: 18_000,
            outputTokens: 5_000,
            reasoningOutputTokens: 3_000,
            totalTokens: 89_000
        )
        let forkChild = AccountThreadTokenUsage(
            inputTokens: 64_000,
            cachedInputTokens: 60_000,
            nonCachedInputTokens: 4_000,
            outputTokens: 4_000,
            reasoningOutputTokens: 1_500,
            totalTokens: 68_000
        )
        return AccountThreadAttributionSummary(
            generatedAt: now,
            rolloutCount: 3,
            topLevelTaskCount: 1,
            riskCounts: AccountThreadAttributionRiskCounts(
                childShare: 1,
                fullContextFork: 1,
                dataQuality: 0
            ),
            tasks: [
                AccountThreadAttributionTask(
                    threadID: "visual-parent-task",
                    status: "top_level",
                    statusLabel: "顶层 task",
                    ownTokens: parent,
                    childTokens: child,
                    mergedTokens: merged,
                    childTaskCount: 2,
                    forkChildCount: 1,
                    childShare: 0.887,
                    childShareAbnormal: true,
                    fullContextForkRisk: true,
                    riskMessages: [
                        "归属子任务占合并总量 88.7%，请展开核对父/子拆分。",
                        "检测到 fork 子任务缓存输入占比较高，可能存在完整上下文复制风险。"
                    ],
                    children: [
                        AccountThreadAttributionChild(
                            threadID: "visual-direct-child",
                            relation: "child",
                            depth: 1,
                            metadataStatus: "ok",
                            tokens: directChild,
                            rolloutCount: 1
                        ),
                        AccountThreadAttributionChild(
                            threadID: "visual-fork-child",
                            relation: "fork",
                            depth: 1,
                            metadataStatus: "ok",
                            tokens: forkChild,
                            rolloutCount: 1
                        )
                    ],
                    rolloutCount: 3
                )
            ]
        )
    }

    private static func sampleManagedProjects(now: Date) -> AccountManagedProjects {
        let json = #"""
        {
          "generated_at":"2026-07-29T08:00:00Z",
          "projects":[{
            "id":"project-frontend-1",
            "name":"GEO 前端",
            "cwd":"/Users/example/program/GEO/frontend",
            "command":"npm run dev -- --host 127.0.0.1 --port 5173",
            "port":5173,
            "pid":28321,
            "pgid":28321,
            "state":"running",
            "state_label":"运行中",
            "reason":"受管进程 PID 28321 正在运行。",
            "action_hint":"可打开服务，或停止后释放端口。",
            "can_start":false,
            "can_stop":true,
            "can_remove":true,
            "can_open":true,
            "service_url":"http://127.0.0.1:5173",
            "service_kind":"web",
            "port_listening":true,
            "port_owner_pid":28321,
            "port_owner_command":"node vite --port 5173"
          }],
          "discovered_services":[{
            "id":"discovered-hyperframes-3018",
            "name":"hyperframes-day2",
            "source":"codex_task",
            "source_task_ids":["task-preview-1"],
            "cwd":"/Users/example/program/sources/hyperframes-day2",
            "command":"npm run dev -- --port 3018",
            "port":3018,
            "state":"listening",
            "state_label":"当前监听",
            "port_listening":true,
            "port_owner_pid":22946,
            "port_owner_command":"node hyperframes preview --port 3018",
            "can_register":true,
            "reason":"来自 Codex 任务记录，可登记为项目服务",
            "action_hint":"登记后可一键启动、停止和打开服务。",
            "can_open":true,
            "service_url":"http://127.0.0.1:3018",
            "service_kind":"web",
            "last_seen_at_ms":1784079539882
          }],
          "codex_tasks":[{
            "id":"task-frontend-1",
            "task_id":"conversation-frontend",
            "cwd":"/Users/example/program/GEO/frontend",
            "command":"npm run dev -- --host 127.0.0.1 --port 5173",
            "pid":null,
            "state":"running_by_port",
            "state_label":"端口仍在监听",
            "kind":"task_process",
            "related_ports":[5173],
            "port_owner_pid":28321,
            "updated_at_ms":1784079539882,
            "can_stop":false
          }],
          "browser_processes":[{
            "id":"process:24109",
            "task_label":"ya-fundmind-v23",
            "pid":24109,
            "state":"running",
            "state_label":"运行中",
            "kind":"browser_automation",
            "command":"node playwright-core/lib/entry/cliDaemon.js ya-fundmind-v23",
            "can_stop":true,
            "fingerprint":"27285573166fa849"
          }],
          "errors":{"processes":null,"ports":null}
        }
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(AccountManagedProjects.self, from: Data(json.utf8))
    }

    private static func sampleDesktopClientSelection(
        for fixture: WorkbenchVisualAcceptanceConfiguration.Fixture
    ) -> DesktopClientSelectionResult {
        let chatGPT = DiagnosticAppInstallation(
            url: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            bundleIdentifier: CodexIntegration.bundleIdentifier,
            version: "1.2026.190",
            isRunning: fixture != .codexCompatibility,
            processIdentifier: fixture != .codexCompatibility ? 42 : nil
        )
        let codex = DiagnosticAppInstallation(
            url: URL(fileURLWithPath: "/Applications/Codex.app"),
            bundleIdentifier: CodexIntegration.bundleIdentifier,
            version: "1.2026.180",
            isRunning: fixture == .codexCompatibility || fixture == .ambiguousClient,
            processIdentifier: fixture == .codexCompatibility || fixture == .ambiguousClient
                ? 84
                : nil
        )
        return DesktopClientTargetSelector.select(
            installations: [chatGPT, codex],
            selectedURL: chatGPT.url
        )
    }

    private static func sampleEvents(now: Date) -> [OperationEvent] {
        [
            OperationEvent(
                schemaVersion: 1,
                id: "visual-client-restart",
                occurredAt: now.addingTimeInterval(-180),
                recordedAt: now.addingTimeInterval(-175),
                category: .system,
                action: "desktop_client_verified",
                title: "已核实 ChatGPT 桌面客户端",
                summary: "运行路径与进程身份均已确认。",
                status: .success,
                importance: .important,
                certainty: .confirmed,
                actor: EventActor(
                    type: .app,
                    id: "codex-workbench",
                    label: "Codex 工作台"
                ),
                thread: EventThread(
                    id: "22222222-2222-4222-8222-222222222222",
                    title: "接续：工作台发行",
                    relation: .activeAtTime
                ),
                project: EventProject(
                    name: "tools",
                    path: "/Users/example/program/tools"
                ),
                evidence: [
                    EventEvidence(kind: "process_identity", label: "App path + PID"),
                ]
            ),
            OperationEvent(
                schemaVersion: 1,
                id: "visual-context-summary",
                occurredAt: now.addingTimeInterval(-900),
                recordedAt: now.addingTimeInterval(-890),
                category: .context,
                action: "context_summary_created",
                title: "生成上下文摘要",
                summary: "压缩前保存了任务事实与下一步。",
                status: .success,
                importance: .important,
                certainty: .confirmed,
                actor: EventActor(type: .hook, id: "precompact", label: "PreCompact Hook"),
                thread: EventThread(
                    id: "11111111-1111-4111-8111-111111111111",
                    title: "Codex 工作台产品化",
                    relation: .source
                ),
                project: EventProject(
                    name: "tools",
                    path: "/Users/example/program/tools"
                )
            ),
        ]
    }

    private static func sampleProfile(
        name: String,
        remainingPercent: Double,
        resetCreditCount: Int,
        now: Date,
        includeOfficialUsage: Bool = true
    ) -> AccountProfile {
        let expiryBase = now.addingTimeInterval(27 * 24 * 60 * 60).timeIntervalSince1970
        let cards = (0..<resetCreditCount).map { index in
            AccountResetCreditCard(
                id: "visual-fixture-\(name)-\(index)",
                status: "available",
                used: false,
                resetType: "full",
                title: "Full reset",
                description: "视觉验收样例，不会执行真实额度重置。",
                expiresAt: expiryBase + Double(index * 86_400)
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let dailyUsage = (0..<30).compactMap { index -> AccountDailyUsageBucket? in
            guard let date = calendar.date(byAdding: .day, value: index - 29, to: today) else {
                return nil
            }
            let weekdayPulse = index % 7 == 5 ? 3_600 : 0
            let tokens = 2_200 + ((index * 977 + name.count * 241) % 7_800) + weekdayPulse
            return AccountDailyUsageBucket(startDate: formatter.string(from: date), tokens: tokens)
        }
        let lastSevenTokens = dailyUsage.suffix(7).reduce(0) { $0 + $1.tokens }
        let peakDailyTokens = dailyUsage.map(\.tokens).max()
        return AccountProfile(
            name: name,
            auth: "present",
            config: "present",
            rateLimits: AccountRateLimits(
                planType: "plus",
                primary: AccountQuotaWindow(
                    usedPercent: 100 - remainingPercent,
                    remainingPercent: remainingPercent,
                    windowMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970
                ),
                secondary: nil,
                resetCredits: AccountResetCredits(
                    available: true,
                    availableCount: resetCreditCount
                )
            ),
            resetCreditDetails: AccountResetCreditDetails(
                available: true,
                availableCount: resetCreditCount,
                totalEarnedCount: resetCreditCount,
                credits: cards,
                earliestExpiresAt: cards.first?.expiresAt
            ),
            remoteStale: false,
            remoteError: nil,
            account: AccountStatusSummary(
                available: true,
                type: "chatgpt",
                planType: "plus",
                emailPresent: false,
                requiresOpenAIAuth: true
            ),
            resetCreditStale: false,
            resetCreditError: nil,
            usage: includeOfficialUsage
                ? AccountUsage(
                    summary: AccountUsageSummary(
                        lifetimeTokens: 2_481_920,
                        peakDailyTokens: peakDailyTokens,
                        longestRunningTurnSec: 418,
                        currentStreakDays: 12,
                        longestStreakDays: 31
                    ),
                    dailyUsageBuckets: dailyUsage
                )
                : nil,
            usageMetrics: includeOfficialUsage
                ? AccountUsageMetrics(
                    todayTokens: dailyUsage.last?.tokens,
                    todayAvailable: true,
                    last7Tokens: lastSevenTokens,
                    last14Tokens: dailyUsage.suffix(14).reduce(0) { $0 + $1.tokens },
                    latestDate: dailyUsage.last?.startDate,
                    source: "app_server"
                )
                : nil
        )
    }

    private static func sampleLocalTokenSnapshot(now: Date) -> AccountLocalTokenSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let daily = (0..<30).compactMap { index -> AccountTokenUsageByDate? in
            guard let date = calendar.date(byAdding: .day, value: index - 29, to: today) else {
                return nil
            }
            let total = 1_400 + ((index * 631) % 5_400)
            return AccountTokenUsageByDate(
                date: formatter.string(from: date),
                inputTokens: total * 3 / 5,
                cachedInputTokens: total / 10,
                outputTokens: total / 5,
                reasoningOutputTokens: total / 10,
                totalTokens: total
            )
        }
        let totalTokens = daily.reduce(0) { $0 + $1.totalTokens }
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]
        return AccountLocalTokenSnapshot(
            eventCount: 30,
            latestTimestamp: timestampFormatter.string(from: now),
            total: AccountTokenUsageTotals(
                inputTokens: totalTokens * 3 / 5,
                cachedInputTokens: totalTokens / 10,
                outputTokens: totalTokens / 5,
                reasoningOutputTokens: totalTokens / 10,
                totalTokens: totalTokens
            ),
            daily: daily,
            byModel: []
        )
    }

    private static func sampleWorkspaceCatalog(now: Date) -> WorkspaceCatalogPresentation {
        let source = WorkspaceThreadPresentation(
            id: "11111111-1111-4111-8111-111111111111",
            title: "Codex 工作台产品化",
            projectName: "tools",
            projectPath: "/Users/example/program/tools",
            updatedAt: now.addingTimeInterval(-3_600),
            sourceThreadID: nil,
            sourceThreadTitle: nil,
            hasContextSummary: true,
            contextTopic: "工作台产品化"
        )
        let continued = WorkspaceThreadPresentation(
            id: "22222222-2222-4222-8222-222222222222",
            title: "接续：工作台发行",
            projectName: "tools",
            projectPath: "/Users/example/program/tools",
            updatedAt: now.addingTimeInterval(-600),
            sourceThreadID: source.id,
            sourceThreadTitle: source.title,
            hasContextSummary: false,
            contextTopic: nil
        )
        let hook = WorkflowItemPresentation(
            id: "fixture-hook",
            name: "上下文摘要 Hook",
            status: "enabled",
            schedule: nil,
            purpose: "压缩前生成任务摘要",
            modifiedAt: now.addingTimeInterval(-1_800),
            kind: .hook
        )
        let automation = WorkflowItemPresentation(
            id: "fixture-automation",
            name: "每周回顾",
            status: "active",
            schedule: "MON 09:00",
            purpose: "整理本周任务证据",
            modifiedAt: now.addingTimeInterval(-1_200),
            kind: .automation
        )
        let rule = WorkflowItemPresentation(
            id: "fixture-rule",
            name: "Codex 全局规则",
            status: "active",
            schedule: nil,
            purpose: "约束默认语言、验证与安全边界",
            modifiedAt: now.addingTimeInterval(-900),
            kind: .rule
        )
        let skill = WorkflowItemPresentation(
            id: "skill:frontend-design-workflow",
            name: "frontend-design-workflow",
            status: "installed",
            schedule: nil,
            purpose: "从需求、外部设计到截图验收的前端工作流",
            modifiedAt: now.addingTimeInterval(-600),
            kind: .skill,
            source: .installedCopy,
            copyState: .matchingCopies
        )
        let plugin = WorkflowItemPresentation(
            id: "fixture-plugin",
            name: "Personal Plugin",
            status: "installed",
            schedule: nil,
            purpose: "提供个人工作流扩展",
            modifiedAt: now.addingTimeInterval(-2_400),
            kind: .plugin
        )
        let configuration = WorkflowItemPresentation(
            id: "fixture-configuration",
            name: "config.toml",
            status: "active",
            schedule: nil,
            purpose: "本机 Codex 配置",
            modifiedAt: now.addingTimeInterval(-3_000),
            kind: .configuration
        )
        return WorkspaceCatalogPresentation(
            projects: [
                WorkspaceProjectPresentation(
                    name: "tools",
                    path: "/Users/example/program/tools",
                    updatedAt: continued.updatedAt,
                    threads: [continued, source]
                )
            ],
            recentThreads: [continued, source],
            contextSummaryCount: 1,
            workflows: WorkflowCatalogPresentation(
                hooks: [hook],
                automations: [automation],
                assets: [rule, skill, hook, automation, plugin, configuration]
            )
        )
    }

    private static func sampleDiagnosticSnapshot(
        ambiguous: Bool = false
    ) -> WorkbenchDiagnosticSnapshot {
        WorkbenchDiagnosticsBuilder.build(
            WorkbenchDiagnosticInput(
                installedApps: [
                    DiagnosticAppInstallation(
                        url: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                        bundleIdentifier: CodexIntegration.bundleIdentifier,
                        version: "1.2026.190",
                        isRunning: true,
                        processIdentifier: 42
                    ),
                    DiagnosticAppInstallation(
                        url: URL(fileURLWithPath: "/Applications/Codex.app"),
                        bundleIdentifier: CodexIntegration.bundleIdentifier,
                        version: "1.2026.180",
                        isRunning: ambiguous,
                        processIdentifier: ambiguous ? 84 : nil
                    ),
                ],
                selectedAppURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                backendAvailable: true,
                accountMode: .managedProfiles,
                accountStorageMode: .unifiedVault,
                managedProfileCount: 2,
                defaultHomeAvailable: true
            )
        )
    }
}
