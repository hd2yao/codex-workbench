import CodexWorkbenchCore
import Foundation

func runWorkbenchVisualAcceptanceTests(_ runner: inout TestRunner) {
    let disabled = WorkbenchVisualAcceptanceConfiguration.parse(environment: [:])
    runner.expect(disabled.fixture == nil, "Visual fixture must be disabled by default")
    runner.expect(disabled.appearance == nil, "Visual appearance must follow the system by default")

    let configured = WorkbenchVisualAcceptanceConfiguration.parse(environment: [
        "CODEX_WORKBENCH_VISUAL_FIXTURE": "switching",
        "CODEX_WORKBENCH_VISUAL_APPEARANCE": "dark",
        "CODEX_WORKBENCH_VISUAL_SURFACE": "menu",
        "CODEX_WORKBENCH_VISUAL_MODULE": "overview",
    ])
    runner.expect(configured.fixture == .switching, "Known fixture names should be parsed")
    runner.expect(configured.appearance == .dark, "Known appearance names should be parsed")
    runner.expect(configured.surface == .menu, "Known visual surfaces should be parsed")
    runner.expect(configured.module == .overview, "Known visual modules should be parsed")
    runner.expect(!configured.liveOperationsAllowed, "Fixture mode must block live account operations")
    runner.expect(
        !WorkbenchStartupPolicy.shouldMigrateLoginItem(configuration: configured),
        "Fixture mode must not register, unregister, or migrate login items"
    )
    runner.expect(
        configured.windowSceneID == "visual-acceptance",
        "Fixture windows must not reuse the production window autosave identity"
    )

    let appearanceOnly = WorkbenchVisualAcceptanceConfiguration.parse(environment: [
        "CODEX_WORKBENCH_VISUAL_APPEARANCE": "dark",
    ])
    runner.expect(
        appearanceOnly.liveOperationsAllowed,
        "Process-only appearance overrides must preserve normal workbench behavior"
    )
    runner.expect(
        WorkbenchVisualAcceptanceConfiguration.parse(environment: [
            "CODEX_WORKBENCH_VISUAL_SURFACE": "menu",
        ]).surface == nil,
        "Visual preview surfaces must require a fixture"
    )
    runner.expect(
        WorkbenchVisualAcceptanceConfiguration.parse(environment: [
            "CODEX_WORKBENCH_VISUAL_MODULE": "overview",
        ]).module == nil,
        "Visual preview modules must require a fixture"
    )
    runner.expect(disabled.liveOperationsAllowed, "Normal launches must preserve live operations")
    runner.expect(
        WorkbenchStartupPolicy.shouldMigrateLoginItem(configuration: disabled),
        "Normal launches should retain the one-time login-item migration"
    )
    runner.expect(disabled.windowSceneID == "main", "Normal launches must retain the production window identity")

    let ignored = WorkbenchVisualAcceptanceConfiguration.parse(environment: [
        "CODEX_WORKBENCH_VISUAL_FIXTURE": "production",
        "CODEX_WORKBENCH_VISUAL_APPEARANCE": "sepia",
        "CODEX_WORKBENCH_VISUAL_SURFACE": "settings",
    ])
    runner.expect(ignored.fixture == nil, "Unknown fixtures must not change production behavior")
    runner.expect(ignored.appearance == nil, "Unknown appearances must not change production behavior")
    runner.expect(ignored.surface == nil, "Unknown visual surfaces must not change production behavior")

    let stale = WorkbenchVisualAcceptanceSnapshot.make(for: .stale)
    runner.expect(stale.payload?.activeProfile == "hd-sarah-blackwell", "Stale fixture should retain a current account")
    runner.expect(
        stale.errorMessage == "账号状态刷新失败。正在展示 10 分钟前成功读取的暂存数据。",
        "Stale fixture should reuse the production cache-age wording"
    )
    runner.expect(stale.switchingProfile == nil, "Stale fixture must not pretend a switch is running")
    runner.expect(stale.blocksLiveOperations, "Fixture states must block real account operations")

    let error = WorkbenchVisualAcceptanceSnapshot.make(for: .error)
    runner.expect(error.payload == nil, "Error fixture should cover the unavailable account state")
    runner.expect(error.errorMessage?.contains("无法读取") == true, "Error fixture should expose a safe user-facing reason")

    let switching = WorkbenchVisualAcceptanceSnapshot.make(for: .switching)
    runner.expect(switching.payload?.activeProfile == "hd-sarah-blackwell", "Switching fixture should preserve the source account")
    runner.expect(switching.switchingProfile == "hd-master", "Switching fixture should target the other account")
    runner.expect(
        switching.banner == "视觉验收模式 · 不执行真实账号操作",
        "Fixture screenshots must visibly disclose synthetic state"
    )
    runner.expect(
        switching.payload?.profiles.contains(where: { $0.name == "hd-master" }) == true,
        "Fixture should cover the alternate account row"
    )
    let currentUsage = switching.payload?.profiles.first(where: {
        $0.name == switching.payload?.activeProfile
    })?.usage?.dailyUsageBuckets
    runner.expect(
        currentUsage?.count == 30,
        "The account visual fixture should provide a deterministic thirty-day trend"
    )
    runner.expect(
        switching.workspaceCatalog.recentThreads.count == 2
            && switching.workspaceCatalog.workflows.hooks.count == 1,
        "Visual fixtures should provide deterministic task and workflow evidence"
    )
    runner.expect(
        switching.desktopClientSelection.target?.displayName == "ChatGPT"
            && switching.desktopClientSelection.target?.processIdentifier == 42,
        "The primary fixture should identify the exact running ChatGPT client"
    )
    runner.expect(
        switching.desktopClientSelection.target?.restartLabel == "重启 ChatGPT",
        "Toolbar and restart copy should derive from the selected client"
    )
    runner.expect(
        switching.payload?.accountStorage.mode == .unifiedVault,
        "The primary managed fixture should exercise unified Codex Home storage"
    )
    runner.expect(
        switching.events.first?.project?.name == "tools"
            && switching.events.first?.thread?.title != nil
            && switching.events.first?.status == .success
            && switching.events.first?.certainty == .confirmed,
        "Activity previews should carry project, thread, status, and certainty"
    )
    let insights = AccountPresentationBuilder.workspaceInsights(payload: switching.payload)
    runner.expect(
        insights.projectsAvailable && !insights.projects.isEmpty,
        "Visual fixtures should make project rankings available when project evidence is shown"
    )
    runner.expect(
        insights.toolsAvailable && !insights.tools.isEmpty,
        "Visual fixtures should make related-tool evidence available"
    )
    runner.expect(
        switching.workspaceCatalog.workflows.assets.contains { $0.kind == .skill }
            && switching.workspaceCatalog.workflows.assets.contains { $0.kind == .rule },
        "Visual fixtures should expose workflow assets instead of a Skill usage ranking"
    )

    let local = WorkbenchVisualAcceptanceSnapshot.make(for: .local)
    runner.expect(local.payload?.accountMode == .localDefault, "Local fixture should use default-home mode")
    let localTrend = local.payload.flatMap { payload in
        payload.profiles.first.map {
            AccountUsageTrendBuilder.build(
                profile: $0,
                localSnapshot: payload.localSnapshot,
                period: .days30,
                today: local.lastUpdatedAt
            )
        }
    }
    runner.expect(
        localTrend?.source == .localFallback && localTrend?.points.count == 30,
        "Local visual evidence should exercise the explicit thirty-day fallback"
    )

    let restartError = WorkbenchVisualAcceptanceSnapshot.make(for: .restartError)
    runner.expect(
        restartError.errorMessage?.contains("同一路径的额外主进程") == true
            && restartError.payload != nil
            && restartError.blocksLiveOperations,
        "Restart-error evidence must be distinct from an unavailable account data source"
    )
    runner.expect(
        local.payload?.profiles.map(\.name) == ["local-default"],
        "Local fixture must not invent another switch target"
    )

    let confirmation = WorkbenchVisualAcceptanceSnapshot.make(for: .restartConfirmation)
    runner.expect(
        confirmation.restartConfirmationReason == .runningTask,
        "Restart confirmation fixture should expose a running-task risk"
    )

    let restarting = WorkbenchVisualAcceptanceSnapshot.make(for: .restarting)
    runner.expect(
        restarting.restartStage == .verifying,
        "Restart progress fixture should expose a concrete stage"
    )

    let diagnostics = WorkbenchVisualAcceptanceSnapshot.make(for: .diagnostics)
    runner.expect(diagnostics.presentsDiagnostics, "Diagnostics fixture should open the real sheet")
    runner.expect(
        diagnostics.diagnosticSnapshot.findings.contains { $0.id == "duplicate-codex-apps" },
        "Diagnostics fixture should provide a deterministic actionable finding"
    )

    let codexCompatibility = WorkbenchVisualAcceptanceSnapshot.make(
        for: .codexCompatibility
    )
    runner.expect(
        codexCompatibility.desktopClientSelection.target?.displayName == "Codex"
            && codexCompatibility.desktopClientSelection.target?.restartLabel == "重启 Codex",
        "The compatibility fixture should keep exact Codex presentation"
    )

    let ambiguous = WorkbenchVisualAcceptanceSnapshot.make(for: .ambiguousClient)
    runner.expect(
        ambiguous.desktopClientSelection.status == .ambiguous
            && ambiguous.desktopClientSelection.target == nil,
        "Multiple running main clients should produce a non-actionable fixture"
    )
    runner.expect(
        ambiguous.presentsDiagnostics
            && ambiguous.diagnosticSnapshot.findings.contains {
                $0.id == "desktop-client-ambiguous"
            },
        "The ambiguous fixture should open the actionable exact-client diagnostic"
    )

    let legacy = WorkbenchVisualAcceptanceSnapshot.make(for: .legacy)
    runner.expect(
        legacy.payload?.accountStorage.mode == .legacyProfiles
            && legacy.payload?.legacyMigration.available == true,
        "Legacy fixture should expose explicit migration without mutating storage"
    )

    let healthy = WorkbenchDataHealthBuilder.build(
        ledgerWarnings: [],
        accountPayloadAvailable: true,
        accountError: nil,
        lastSuccessfulRefresh: switching.lastUpdatedAt,
        desktopClientStatus: .selected,
        now: switching.lastUpdatedAt
    )
    runner.expect(healthy.level == .healthy, "All confirmed sources should be healthy")
    let degraded = WorkbenchDataHealthBuilder.build(
        ledgerWarnings: [],
        accountPayloadAvailable: true,
        accountError: "远端额度读取失败",
        lastSuccessfulRefresh: switching.lastUpdatedAt,
        desktopClientStatus: .selected,
        now: switching.lastUpdatedAt
    )
    runner.expect(
        degraded.level == .degraded,
        "Data health must account for account errors, not only ledger warnings"
    )

    runner.expect(
        WorkbenchInterfaceContract.pageTitleSize == 20
            && WorkbenchInterfaceContract.sectionTitleSize == 13
            && WorkbenchInterfaceContract.bodySize == 13
            && WorkbenchInterfaceContract.captionSize == 12
            && WorkbenchInterfaceContract.microSize == 11,
        "The compact console should keep the approved 20/13/12/11 hierarchy"
    )
}
