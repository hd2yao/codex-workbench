import AppKit
import CodexWorkbenchCore
import Combine
import Foundation

private struct LedgerRefreshResult: Sendable {
    let events: [OperationEvent]
    let warnings: [String]
    let appendedCount: Int
    let snapshot: EvidenceSnapshot
}

private struct AccountRefreshResult: Sendable {
    let payload: AccountDashboardPayload?
    let errorMessage: String?
}

enum AccountSwitchStage: Equatable {
    case switching(profile: String)
    case verifying(profile: String)

    var profile: String {
        switch self {
        case .switching(let profile), .verifying(let profile):
            profile
        }
    }
}

enum AccountRestartStage: Equatable {
    case preparing
    case quitting
    case launching
    case verifying

    init(_ stage: WorkbenchVisualRestartStage) {
        switch stage {
        case .preparing: self = .preparing
        case .quitting: self = .quitting
        case .launching: self = .launching
        case .verifying: self = .verifying
        }
    }
}

@MainActor
final class WorkbenchAppModel: ObservableObject {
    @Published var selectedModule: AppModule? = .overview
    @Published private(set) var events: [OperationEvent] = []
    @Published private(set) var ledgerWarnings: [String] = []
    @Published private(set) var accountPayload: AccountDashboardPayload?
    @Published private(set) var managedProjects: AccountManagedProjects?
    @Published private(set) var accountError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var accountSwitchStage: AccountSwitchStage?
    @Published private(set) var accountRestartStage: AccountRestartStage?
    @Published private(set) var accountRestartConfirmation: AccountRestartConfirmationReason?
    @Published private(set) var legacyMigrationPreview: AccountLegacyMigrationReport?
    @Published private(set) var isMigratingLegacyProfiles = false
    @Published private(set) var isRecoveringAccountVault = false
    @Published private(set) var diagnosticSnapshot = WorkbenchDiagnosticsBuilder.build(
        WorkbenchDiagnosticInput(
            installedApps: [],
            selectedAppURL: nil,
            backendAvailable: false,
            accountMode: .unavailable,
            managedProfileCount: 0,
            defaultHomeAvailable: false
        )
    )
    @Published private(set) var workspaceCatalog = WorkspaceCatalogPresentationBuilder.build(
        catalog: CodexMetadataCatalog(),
        contextCards: [],
        workflowFiles: []
    )
    @Published private(set) var desktopClientSelection = DesktopClientSelectionResult(
        status: .unavailable,
        target: nil,
        candidates: [],
        unavailableReason: "尚未探测桌面客户端"
    )
    @Published private(set) var isCodexRunning = false
    @Published private(set) var isLegacyProfileSwitcherRunning = false
    @Published private(set) var projectActionIDsInFlight: Set<String> = []
    @Published private(set) var projectActionMessage: String?
    @Published private(set) var serviceOpenMessages: [String: String] = [:]
    @Published private(set) var pendingProjectRegistrationKeys: Set<String> = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var accountLastSuccessfulRefresh: Date?
    @Published var searchText = ""
    @Published var importanceFilter: EventImportance?
    @Published var actorFilter: EventActorType?
    @Published var statusFilter: EventStatus?
    @Published var selectedEventID: String?

    private var hasBootstrapped = false
    private var pollingTask: Task<Void, Never>?
    private let ledgerURL: URL
    private let observationStateURL: URL
    private let accountGateway: AccountGateway?
    private let desktopAppProbe: any CodexAppProbing
    private let visualAcceptanceConfiguration: WorkbenchVisualAcceptanceConfiguration
    private let visualAcceptanceSnapshot: WorkbenchVisualAcceptanceSnapshot?
    private let postRestartRefreshEnabled: Bool
    private let officialRateLimitObserver = OfficialRateLimitObserver()
    private let automaticResetCoordinator: AutomaticResetCoordinator?
    private var accountRefreshFreshness = AccountRefreshFreshness()
    private var recentAccountFailureStage: String?
    private var pendingRestartTarget: DesktopClientTarget?

    init() {
        let configuration = WorkbenchVisualAcceptanceConfiguration.parse(
            environment: ProcessInfo.processInfo.environment
        )
        visualAcceptanceConfiguration = configuration
        desktopAppProbe = LiveCodexAppProbe()
        postRestartRefreshEnabled = true
        automaticResetCoordinator = AutomaticResetCoordinator()
        ledgerURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/operation-ledger/events.jsonl")
        observationStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/operation-ledger/state/observation-state.json")
        if let fixture = configuration.fixture {
            let snapshot = WorkbenchVisualAcceptanceSnapshot.make(for: fixture)
            visualAcceptanceSnapshot = snapshot
            accountGateway = nil
            selectedModule = configuration.module ?? .accounts
            accountPayload = snapshot.payload
            managedProjects = snapshot.payload?.managedProjects
            accountError = snapshot.errorMessage
            accountSwitchStage = snapshot.switchingProfile.map { .switching(profile: $0) }
            accountRestartStage = snapshot.restartStage.map(AccountRestartStage.init)
            accountRestartConfirmation = snapshot.restartConfirmationReason
            diagnosticSnapshot = snapshot.diagnosticSnapshot
            workspaceCatalog = snapshot.workspaceCatalog
            desktopClientSelection = snapshot.desktopClientSelection
            events = snapshot.events
            isCodexRunning = snapshot.isCodexRunning
            lastUpdated = snapshot.lastUpdatedAt
            if snapshot.payload != nil {
                accountRefreshFreshness.recordSuccess(at: snapshot.lastUpdatedAt)
                accountLastSuccessfulRefresh = snapshot.lastUpdatedAt
            }
        } else {
            visualAcceptanceSnapshot = nil
            accountGateway = AccountBackendLocator.bundled() ?? Self.developmentAccountGateway()
            updateRunningApplicationState()
        }
        if visualAcceptanceSnapshot == nil {
            refreshDiagnostics()
        }
    }

    init(
        testingGateway: AccountGateway,
        payload: AccountDashboardPayload,
        ledgerURL: URL,
        desktopAppProbe: any CodexAppProbing = LiveCodexAppProbe(),
        testingLegacyProfileSwitcherRunning: Bool = false
    ) {
        visualAcceptanceConfiguration = WorkbenchVisualAcceptanceConfiguration(
            fixture: nil,
            appearance: nil,
            surface: nil
        )
        visualAcceptanceSnapshot = nil
        postRestartRefreshEnabled = false
        automaticResetCoordinator = nil
        self.ledgerURL = ledgerURL
        observationStateURL = ledgerURL.deletingLastPathComponent()
            .appendingPathComponent("observation-state.json")
        accountGateway = testingGateway
        self.desktopAppProbe = desktopAppProbe
        accountPayload = payload
        managedProjects = payload.managedProjects
        accountRefreshFreshness.recordSuccess(at: payload.generatedAt)
        accountLastSuccessfulRefresh = payload.generatedAt
        updateRunningApplicationState()
        isLegacyProfileSwitcherRunning = testingLegacyProfileSwitcherRunning
        refreshDiagnostics()
    }

    var filteredEvents: [OperationEvent] {
        let filter = ActivityFilter(
            query: searchText,
            importances: importanceFilter.map { [$0] } ?? [],
            actorTypes: actorFilter.map { [$0] } ?? [],
            statuses: statusFilter.map { [$0] } ?? []
        )
        return events.filter(filter.matches)
    }

    var selectedEvent: OperationEvent? {
        guard let selectedEventID else { return nil }
        return events.first { $0.id == selectedEventID }
    }

    var todayEventCount: Int {
        events.filter { Calendar.current.isDateInToday($0.occurredAt) }.count
    }

    var todayImportantEventCount: Int {
        events.filter {
            Calendar.current.isDateInToday($0.occurredAt)
                && ($0.importance == .critical || $0.importance == .important)
        }.count
    }

    var attentionCount: Int {
        events.filter {
            Calendar.current.isDateInToday($0.occurredAt)
                && ActivityInsights.requiresAttention($0)
        }.count
    }

    var currentProfileName: String? {
        AccountPresentationBuilder.confirmedCurrentProfileName(payload: accountPayload)
    }

    var desktopProfileName: String? {
        currentProfileName
    }

    var switchingProfile: String? {
        accountSwitchStage?.profile
    }

    var isVisualAcceptanceMode: Bool {
        visualAcceptanceSnapshot != nil
    }

    var desktopClientTarget: DesktopClientTarget? {
        desktopClientSelection.target
    }

    var hasRunningDesktopClients: Bool {
        desktopClientSelection.candidates.contains(where: \.isRunning)
    }

    var desktopClientDisplayName: String {
        desktopClientTarget?.displayName ?? "ChatGPT/Codex"
    }

    var desktopClientOpenLabel: String {
        desktopClientTarget?.openLabel ?? "桌面客户端不可用"
    }

    var desktopClientRestartLabel: String {
        desktopClientTarget?.restartLabel ?? "无法重启桌面客户端"
    }

    var desktopClientUnavailableReason: String? {
        desktopClientSelection.unavailableReason
    }

    var desktopClientIdentityDetail: String {
        guard let target = desktopClientTarget else {
            return desktopClientUnavailableReason ?? "未选择桌面客户端"
        }
        let process = target.processIdentifier.map { "PID \($0)" } ?? "未运行"
        return "\(target.appURL.path) · \(process) · \(target.selectionReason.displayName)"
    }

    var dataHealthPresentation: WorkbenchDataHealthPresentation {
        WorkbenchDataHealthBuilder.build(
            ledgerWarnings: ledgerWarnings,
            accountPayloadAvailable: accountPayload != nil,
            accountError: accountOperationError == nil ? accountError : nil,
            lastSuccessfulRefresh: accountLastSuccessfulRefresh ?? lastUpdated,
            desktopClientStatus: desktopClientSelection.status
        )
    }

    var accountErrorNoticeTitle: String {
        accountOperationError == nil ? "账号数据已降级" : "账号操作未完成"
    }

    private var accountOperationError: String? {
        guard let accountError else { return nil }
        if recentAccountFailureStage != nil
            || accountError.contains("重启未完成")
            || accountError.contains("重启未通过")
            || accountError.contains("账号切换")
        {
            return accountError
        }
        return nil
    }

    var visualAcceptanceBanner: String? {
        visualAcceptanceSnapshot?.banner
    }

    var visualAcceptanceSurface: WorkbenchVisualAcceptanceConfiguration.Surface? {
        visualAcceptanceConfiguration.surface
    }

    var visualAcceptanceShowsDiagnostics: Bool {
        visualAcceptanceSnapshot?.presentsDiagnostics == true
    }

    var windowSceneID: String {
        visualAcceptanceConfiguration.windowSceneID
    }

    var runtimePresentation: AccountRuntimePresentation {
        AccountPresentationBuilder.runtime(status: accountPayload?.runtimeStatus)
    }

    var accountAutomationAvailability: AccountAutomationAvailability {
        AccountRuntimePolicy.automationAvailability(
            accountMode: accountPayload?.accountMode ?? .unavailable,
            storageMode: accountPayload?.accountStorage.mode,
            legacyProfileSwitcherRunning: isLegacyProfileSwitcherRunning
        )
    }

    var canRecoverAccountVault: Bool {
        !isVisualAcceptanceMode
            && !isRecoveringAccountVault
            && !isLegacyProfileSwitcherRunning
            && !hasRunningDesktopClients
            && accountError?.contains("上次账号事务尚未收敛") == true
    }

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        guard visualAcceptanceConfiguration.liveOperationsAllowed else { return }
        automaticResetCoordinator?.start()
        Task { await refreshAll() }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refreshAll(refreshResetCredits: true)
            }
        }
    }

    func refreshAll(refreshResetCredits: Bool = false) async {
        guard visualAcceptanceConfiguration.liveOperationsAllowed else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        updateRunningApplicationState()

        let ledgerURL = ledgerURL
        async let ledgerResult: LedgerRefreshResult = Task.detached(priority: .userInitiated) {
            let snapshot = LocalEvidenceReader().read()
            let reconciled = EvidenceReconciler().events(from: snapshot)
            let writeResult = LedgerWriter().append(events: reconciled, to: ledgerURL)
            let pruneResult = LedgerMaintenance().prune(
                actions: ["quota_usage_updated", "quota_reset_time_updated"],
                from: ledgerURL
            )
            let loaded = LedgerRepository().load(from: ledgerURL)
            return LedgerRefreshResult(
                events: loaded.events,
                warnings: snapshot.warnings
                    + writeResult.warnings
                    + pruneResult.warnings
                    + loaded.warnings.map(\.message),
                appendedCount: writeResult.appendedCount,
                snapshot: snapshot
            )
        }.value

        let gateway = accountGateway
        async let accountResult: AccountRefreshResult = Task.detached(priority: .utility) {
            guard let gateway else {
                return AccountRefreshResult(payload: nil, errorMessage: "未找到账号模块。")
            }
            do {
                let payload = try gateway.loadStatus(refreshResetCredits: refreshResetCredits)
                return AccountRefreshResult(payload: payload, errorMessage: nil)
            } catch {
                return AccountRefreshResult(
                    payload: nil,
                    errorMessage: (error as? LocalizedError)?.errorDescription ?? "无法读取账号状态。"
                )
            }
        }.value

        let ledger = await ledgerResult
        let account = await accountResult
        workspaceCatalog = WorkspaceCatalogPresentationBuilder.build(
            catalog: ledger.snapshot.threadCatalog,
            contextCards: ledger.snapshot.contextCards,
            workflowFiles: ledger.snapshot.workflowFiles
        )
        let accountRefreshCompletedAt = Date()
        if let payload = account.payload {
            accountPayload = payload
            managedProjects = payload.managedProjects
            accountRefreshFreshness.recordSuccess(at: accountRefreshCompletedAt)
            accountLastSuccessfulRefresh = accountRefreshCompletedAt
            accountError = nil
        } else if let errorMessage = account.errorMessage {
            accountError = accountRefreshFreshness.failureMessage(
                error: errorMessage,
                hasCachedPayload: accountPayload != nil,
                now: accountRefreshCompletedAt
            )
        }

        let observationStateURL = observationStateURL
        let observedAt = Date()
        let observationResult = await Task.detached(priority: .utility) {
            let store = ObservationStateStore()
            let previous = store.load(from: observationStateURL)
            let reconciliation = ObservationStateReconciler().reconcile(
                previous: previous,
                evidence: ledger.snapshot,
                accountPayload: account.payload,
                accountError: account.errorMessage,
                existingEvents: ledger.events,
                observedAt: observedAt
            )
            let writeResult = LedgerWriter().append(events: reconciliation.events, to: ledgerURL)
            let didSave = store.save(reconciliation.state, to: observationStateURL)
            let loaded = LedgerRepository().load(from: ledgerURL)
            let contextRevisions = ContextEventHistoryEnricher().revisions(
                events: loaded.events,
                cards: ledger.snapshot.contextCards,
                catalog: ledger.snapshot.threadCatalog,
                recordedAt: observedAt
            )
            let workflowRevisions = WorkflowEventHistoryEnricher().revisions(
                events: loaded.events,
                catalog: ledger.snapshot.threadCatalog,
                currentWorkflowFiles: ledger.snapshot.workflowFiles,
                recordedAt: observedAt
            )
            let revisionWriteResult = LedgerWriter().appendRevisions(
                events: contextRevisions + workflowRevisions,
                to: ledgerURL
            )
            let finalLedger = revisionWriteResult.appendedCount > 0
                ? LedgerRepository().load(from: ledgerURL)
                : loaded
            var warnings = ledger.warnings
                + writeResult.warnings
                + revisionWriteResult.warnings
                + finalLedger.warnings.map(\.message)
            if !didSave {
                warnings.append("无法保存操作日志观察基线。")
            }
            return LedgerRefreshResult(
                events: EventContextEnricher().enrich(
                    events: finalLedger.events,
                    catalog: ledger.snapshot.threadCatalog
                ),
                warnings: warnings,
                appendedCount: ledger.appendedCount
                    + writeResult.appendedCount
                    + revisionWriteResult.appendedCount,
                snapshot: ledger.snapshot
            )
        }.value

        events = observationResult.events
        ledgerWarnings = observationResult.warnings
        configureOfficialRateLimitObserver()
        refreshDiagnostics()
        lastUpdated = Date()
        isRefreshing = false
        if let payload = account.payload {
            automaticResetCoordinator?.process(
                payload: payload,
                gateway: accountGateway
            ) { [weak self] _, _ in
                Task { await self?.refreshAll(refreshResetCredits: true) }
            }
        }
    }

    func addManagedProject(
        name: String,
        cwd: String,
        command: String,
        port: Int?,
        adoptCurrent: Bool = false
    ) {
        guard let gateway = accountGateway else { return }
        let registrationKey = managedProjectRegistrationKey(cwd: cwd, command: command, port: port)
        let actionID = "registration:\(registrationKey)"
        guard !projectActionIDsInFlight.contains(actionID) else { return }
        projectActionIDsInFlight.insert(actionID)
        pendingProjectRegistrationKeys.insert(registrationKey)
        projectActionMessage = "正在登记 \(name)…"
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try gateway.addManagedProject(
                        name: name,
                        cwd: cwd,
                        command: command,
                        port: port,
                        adoptCurrent: adoptCurrent
                    )
                }.value
                guard let self else { return }
                let refreshError = await self.refreshManagedProjects()
                self.pendingProjectRegistrationKeys.remove(registrationKey)
                self.projectActionIDsInFlight.remove(actionID)
                self.projectActionMessage = refreshError == nil
                    ? "已登记 \(name)。现在可在“工作台项目”中启动、停止或打开服务。"
                    : "已登记 \(name)，但列表刷新失败：\(refreshError!)"
            } catch {
                guard let self else { return }
                _ = await self.refreshManagedProjects()
                self.pendingProjectRegistrationKeys.remove(registrationKey)
                self.projectActionIDsInFlight.remove(actionID)
                self.projectActionMessage = (error as? LocalizedError)?.errorDescription
                    ?? "项目服务操作失败。"
            }
        }
    }

    func startManagedProject(_ projectID: String) {
        runManagedProjectAction("启动", actionID: "project:\(projectID)") { gateway in
            try gateway.startManagedProject(projectID)
        }
    }

    func switchManagedProject(_ projectID: String) {
        runManagedProjectAction("切换启动", actionID: "project:\(projectID)") { gateway in
            try gateway.switchManagedProject(projectID)
        }
    }

    func stopManagedProject(_ projectID: String) {
        runManagedProjectAction("停止", actionID: "project:\(projectID)") { gateway in
            try gateway.stopManagedProject(projectID)
        }
    }

    func removeManagedProject(_ projectID: String) {
        runManagedProjectAction("删除登记", actionID: "project:\(projectID)") { gateway in
            try gateway.removeManagedProject(projectID)
        }
    }

    func pruneDuplicateManagedProjects() {
        runManagedProjectAction("清理重复登记", actionID: "project:prune") { gateway in
            try gateway.pruneDuplicateManagedProjects()
        }
    }

    func stopManagedProcess(pid: Int, fingerprint: String) {
        runManagedProjectAction("结束自动化 Chrome", actionID: "browser:\(pid)") { gateway in
            try gateway.stopManagedProcess(pid: pid, fingerprint: fingerprint)
        }
    }

    func isProjectRegistrationPending(cwd: String, command: String, port: Int?) -> Bool {
        pendingProjectRegistrationKeys.contains(
            managedProjectRegistrationKey(cwd: cwd, command: command, port: port)
        )
    }

    var isProjectActionInFlight: Bool {
        !projectActionIDsInFlight.isEmpty
    }

    func isProjectActionInFlight(_ actionID: String) -> Bool {
        projectActionIDsInFlight.contains(actionID)
    }

    func openManagedService(_ rawURL: String, name: String, serviceID: String) {
        guard let url = URL(string: rawURL), let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            let message = "无法为 \(name) 找到可打开 \(rawURL) 的浏览器。"
            serviceOpenMessages[serviceID] = message
            projectActionMessage = message
            return
        }
        let applicationName = (Bundle(url: applicationURL)?.object(
            forInfoDictionaryKey: "CFBundleName"
        ) as? String) ?? "默认浏览器"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let openingMessage = "正在通过 \(applicationName) 打开并前置 \(name)…"
        serviceOpenMessages[serviceID] = openingMessage
        projectActionMessage = openingMessage
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor [weak self] in
                if let error {
                    let message = "无法打开 \(name)：\(error.localizedDescription)"
                    self?.serviceOpenMessages[serviceID] = message
                    self?.projectActionMessage = message
                } else {
                    application?.activate(options: [.activateAllWindows])
                    let message = "已在 \(applicationName) 前置打开 \(name)。"
                    self?.serviceOpenMessages[serviceID] = message
                    self?.projectActionMessage = message
                }
            }
        }
    }

    private func runManagedProjectAction(
        _ action: String,
        actionID: String,
        operation: @escaping @Sendable (AccountGateway) throws -> Void
    ) {
        guard let gateway = accountGateway, !projectActionIDsInFlight.contains(actionID) else { return }
        projectActionIDsInFlight.insert(actionID)
        projectActionMessage = "正在\(action)…"
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try operation(gateway)
                }.value
                guard let self else { return }
                let refreshError = await self.refreshManagedProjects()
                self.projectActionIDsInFlight.remove(actionID)
                self.projectActionMessage = refreshError == nil
                    ? "已\(action)。"
                    : "已\(action)，但列表刷新失败：\(refreshError!)"
            } catch {
                guard let self else { return }
                _ = await self.refreshManagedProjects()
                self.projectActionIDsInFlight.remove(actionID)
                self.projectActionMessage = "\(action)项目服务失败：\((error as? LocalizedError)?.errorDescription ?? "请刷新后重试。")"
            }
        }
    }

    private func refreshManagedProjects() async -> String? {
        guard let gateway = accountGateway else { return "未找到账号模块。" }
        do {
            let projects = try await Task.detached(priority: .userInitiated) {
                try gateway.loadManagedProjects()
            }.value
            managedProjects = projects
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "无法读取项目服务状态。"
        }
    }

    private func managedProjectRegistrationKey(cwd: String, command: String, port: Int?) -> String {
        let normalizedPath = URL(fileURLWithPath: cwd)
            .standardizedFileURL
            .path
        return "\(normalizedPath)\u{0}\(command.trimmingCharacters(in: .whitespacesAndNewlines))\u{0}\(port.map(String.init) ?? "")"
    }

    func handleSystemWake() {
        Task { await refreshAll(refreshResetCredits: true) }
    }

    func selectEvent(_ event: OperationEvent) {
        selectedEventID = selectedEventID == event.id ? nil : event.id
    }

    func switchProfile(_ profile: String) {
        guard visualAcceptanceConfiguration.liveOperationsAllowed else { return }
        guard
            accountSwitchStage == nil,
            accountRestartStage == nil,
            accountRestartConfirmation == nil,
            let gateway = accountGateway,
            let desktopTarget = desktopClientTarget
        else { return }
        accountSwitchStage = .switching(profile: profile)
        let previousProfile = currentProfileName
        Task {
            let switchError = await Task.detached(priority: .userInitiated) {
                do {
                    try gateway.switchProfile(profile, target: desktopTarget)
                    return nil as String?
                } catch {
                    return (error as? LocalizedError)?.errorDescription ?? "账号切换失败。"
                }
            }.value
            if let errorMessage = switchError {
                recordAccountSwitchFailure(
                    expected: profile,
                    actual: previousProfile,
                    reason: "switch_command_failed",
                    clientDisplayName: desktopTarget.displayName
                )
                accountSwitchStage = nil
                accountError = errorMessage
                return
            }

            accountSwitchStage = .verifying(profile: profile)
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return AccountRefreshResult(
                        payload: try gateway.loadStatus(refreshResetCredits: true),
                        errorMessage: nil
                    )
                } catch {
                    return AccountRefreshResult(
                        payload: nil,
                        errorMessage: (error as? LocalizedError)?.errorDescription ?? "无法核对切换后的默认账号。"
                    )
                }
            }.value

            guard let payload = result.payload else {
                recordAccountSwitchFailure(
                    expected: profile,
                    actual: previousProfile,
                    reason: "verification_unavailable",
                    clientDisplayName: desktopTarget.displayName
                )
                accountSwitchStage = nil
                accountError = result.errorMessage ?? "无法核对切换后的默认账号。"
                return
            }
            switch AccountSwitchVerifier.verify(payload: payload, expectedProfile: profile) {
            case .expectedDesktopDefault:
                accountPayload = payload
                let verifiedAt = Date()
                accountRefreshFreshness.recordSuccess(at: verifiedAt)
                accountLastSuccessfulRefresh = verifiedAt
                accountError = nil
                accountSwitchStage = nil
                recordAccountSwitch(
                    from: previousProfile,
                    to: profile,
                    clientDisplayName: desktopTarget.displayName
                )
                if postRestartRefreshEnabled {
                    await refreshAll(refreshResetCredits: true)
                }
            case .mismatch(let expected, let actual):
                recordAccountSwitchFailure(
                    expected: expected,
                    actual: actual,
                    reason: "verification_mismatch",
                    clientDisplayName: desktopTarget.displayName
                )
                accountSwitchStage = nil
                accountError = "账号切换未通过验证：目标为 \(expected)，实际为 \(actual ?? "未知")。"
            case .unmanaged(let actual):
                recordAccountSwitchFailure(
                    expected: profile,
                    actual: actual,
                    reason: "unmanaged_login",
                    clientDisplayName: desktopTarget.displayName
                )
                accountSwitchStage = nil
                accountError = "默认账号切换未通过核对：\(actual ?? "未知账号") 尚未被工作台接管。"
            }
        }
    }

    func requestRestartCurrentCodex() {
        guard visualAcceptanceConfiguration.liveOperationsAllowed else { return }
        guard
            accountSwitchStage == nil,
            accountRestartStage == nil,
            accountRestartConfirmation == nil,
            accountGateway != nil,
            let payload = accountPayload,
            payload.accountMode != .unavailable,
            let profile = currentProfileName,
            let desktopTarget = desktopClientTarget
        else { return }

        switch AccountRestartPolicy.decision(runtimeState: payload.runtimeStatus?.state) {
        case .restartNow:
            performRestartCurrentCodex(
                expectedMode: payload.accountMode,
                profile: profile,
                allowActive: false,
                desktopTarget: desktopTarget
            )
        case .confirm(let reason):
            pendingRestartTarget = desktopTarget
            accountRestartConfirmation = reason
        }
    }

    func confirmRestartCurrentCodex() {
        guard
            accountRestartConfirmation != nil,
            accountRestartStage == nil,
            accountSwitchStage == nil,
            let payload = accountPayload,
            payload.accountMode != .unavailable,
            let profile = currentProfileName,
            let desktopTarget = pendingRestartTarget ?? desktopClientTarget
        else { return }
        accountRestartConfirmation = nil
        pendingRestartTarget = nil
        guard visualAcceptanceConfiguration.liveOperationsAllowed else { return }
        performRestartCurrentCodex(
            expectedMode: payload.accountMode,
            profile: profile,
            allowActive: true,
            desktopTarget: desktopTarget
        )
    }

    func cancelRestartCurrentCodex() {
        guard accountRestartConfirmation != nil else { return }
        let clientDisplayName = pendingRestartTarget?.displayName
            ?? desktopClientDisplayName
        accountRestartConfirmation = nil
        pendingRestartTarget = nil
        guard visualAcceptanceConfiguration.liveOperationsAllowed else { return }
        appendAccountOperationEvent(
            AccountOperationEventFactory.restartCancelled(
                profile: currentProfileName,
                clientDisplayName: clientDisplayName
            )
        )
    }

    func updateRunningApplicationState() {
        let result = desktopAppProbe.probe()
        desktopClientSelection = DesktopClientTargetSelector.select(
            installations: result.installations,
            selectedURL: result.selectedAppURL
        )
        isCodexRunning = desktopClientTarget?.isRunning == true
        isLegacyProfileSwitcherRunning = AccountRuntimeServices.legacyProfileSwitcherIsRunning()
    }

    func refreshDiagnostics() {
        diagnosticSnapshot = AccountRuntimeServices.diagnosticSnapshot(
            payload: accountPayload,
            recentFailureStage: recentAccountFailureStage,
            probe: desktopAppProbe
        )
    }

    func requestLegacyProfileMigration() {
        guard
            visualAcceptanceConfiguration.liveOperationsAllowed,
            !isMigratingLegacyProfiles,
            legacyMigrationPreview == nil,
            AccountPresentationBuilder.storage(payload: accountPayload)
                .canMigrateLegacyProfiles,
            !hasRunningDesktopClients,
            !isLegacyProfileSwitcherRunning,
            let gateway = accountGateway
        else { return }
        isMigratingLegacyProfiles = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try gateway.migrateLegacyProfiles(dryRun: true)
                }
            }.value
            isMigratingLegacyProfiles = false
            switch result {
            case .success(let report):
                accountError = nil
                legacyMigrationPreview = report
            case .failure(let error):
                accountError = (error as? LocalizedError)?.errorDescription
                    ?? "无法检查旧 Profiles 迁移。"
            }
        }
    }

    func confirmLegacyProfileMigration() {
        guard
            visualAcceptanceConfiguration.liveOperationsAllowed,
            legacyMigrationPreview != nil,
            !isMigratingLegacyProfiles,
            !hasRunningDesktopClients,
            !isLegacyProfileSwitcherRunning,
            let gateway = accountGateway
        else { return }
        legacyMigrationPreview = nil
        isMigratingLegacyProfiles = true
        officialRateLimitObserver.stop()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try gateway.migrateLegacyProfiles(dryRun: false)
                }
            }.value
            isMigratingLegacyProfiles = false
            switch result {
            case .success:
                accountError = nil
                await refreshAll(refreshResetCredits: true)
            case .failure(let error):
                configureOfficialRateLimitObserver()
                accountError = (error as? LocalizedError)?.errorDescription
                    ?? "旧 Profiles 迁移未完成。"
            }
        }
    }

    func cancelLegacyProfileMigration() {
        legacyMigrationPreview = nil
    }

    func recoverAccountVault() {
        guard
            canRecoverAccountVault,
            let gateway = accountGateway
        else { return }
        isRecoveringAccountVault = true
        officialRateLimitObserver.stop()
        Task {
            let errorMessage = await Task.detached(priority: .userInitiated) {
                do {
                    try gateway.recoverVault()
                    return nil as String?
                } catch {
                    return (error as? LocalizedError)?.errorDescription
                        ?? "账号库恢复未完成。"
                }
            }.value
            isRecoveringAccountVault = false
            if let errorMessage {
                configureOfficialRateLimitObserver()
                accountError = errorMessage
                return
            }
            accountError = nil
            await refreshAll(refreshResetCredits: true)
        }
    }

    private func recordAccountSwitch(
        from previousProfile: String?,
        to profile: String,
        clientDisplayName: String
    ) {
        recentAccountFailureStage = nil
        appendAccountOperationEvent(
            AccountOperationEventFactory.switchSucceeded(
                from: previousProfile,
                to: profile,
                clientDisplayName: clientDisplayName
            )
        )
        refreshDiagnostics()
    }

    private func recordAccountSwitchFailure(
        expected: String,
        actual: String?,
        reason: String,
        clientDisplayName: String
    ) {
        recentAccountFailureStage = reason
        appendAccountOperationEvent(
            AccountOperationEventFactory.switchFailed(
                expected: expected,
                actual: actual,
                reason: reason,
                clientDisplayName: clientDisplayName
            )
        )
        refreshDiagnostics()
    }

    private func performRestartCurrentCodex(
        expectedMode: AccountMode,
        profile: String,
        allowActive: Bool,
        desktopTarget: DesktopClientTarget
    ) {
        guard let gateway = accountGateway else { return }
        accountRestartStage = .preparing
        let managedProfile = expectedMode == .managedProfiles ? profile : nil

        Task {
            accountRestartStage = .quitting
            let restartError: AccountGatewayError? = await Task.detached(priority: .userInitiated) {
                do {
                    try gateway.restartCurrentAccount(
                        profile: managedProfile,
                        allowActive: allowActive,
                        target: desktopTarget
                    )
                    return nil
                } catch let error as AccountGatewayError {
                    return error
                } catch {
                    return .launchFailed
                }
            }.value
            if let restartError,
               case .restartConfirmationRequired(let reason) = restartError {
                accountRestartStage = nil
                accountRestartConfirmation = reason
                accountError = nil
                return
            }
            if let restartError {
                appendAccountOperationEvent(
                    AccountOperationEventFactory.restartFailed(
                        profile: profile,
                        reason: "restart_command_failed",
                        clientDisplayName: desktopTarget.displayName
                    )
                )
                recentAccountFailureStage = "restart_command_failed"
                refreshDiagnostics()
                accountRestartStage = nil
                accountError = restartError.errorDescription
                    ?? "\(desktopTarget.displayName) 重启失败。"
                return
            }

            accountRestartStage = .launching
            updateRunningApplicationState()
            guard DesktopClientRestartVerifier.verify(
                previous: desktopTarget,
                current: desktopClientTarget
            ) else {
                appendAccountOperationEvent(
                    AccountOperationEventFactory.restartFailed(
                        profile: profile,
                        reason: "desktop_identity_mismatch",
                        clientDisplayName: desktopTarget.displayName
                    )
                )
                recentAccountFailureStage = "desktop_identity_mismatch"
                refreshDiagnostics()
                accountRestartStage = nil
                accountError = "重启未通过验证：桌面客户端身份或进程没有按预期更新。"
                return
            }
            await Task.yield()
            accountRestartStage = .verifying
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return AccountRefreshResult(
                        payload: try gateway.loadStatus(refreshResetCredits: true),
                        errorMessage: nil
                    )
                } catch {
                    return AccountRefreshResult(
                        payload: nil,
                        errorMessage: (error as? LocalizedError)?.errorDescription
                            ?? "无法核对重启后的默认账号。"
                    )
                }
            }.value

            guard let payload = result.payload else {
                appendAccountOperationEvent(
                    AccountOperationEventFactory.restartFailed(
                        profile: profile,
                        reason: "verification_unavailable",
                        clientDisplayName: desktopTarget.displayName
                    )
                )
                recentAccountFailureStage = "verification_unavailable"
                refreshDiagnostics()
                accountRestartStage = nil
                accountError = result.errorMessage ?? "无法核对重启后的默认账号。"
                return
            }

            switch AccountRestartVerifier.verify(
                payload: payload,
                expectedMode: expectedMode,
                expectedProfile: profile
            ) {
            case .verified:
                accountPayload = payload
                let verifiedAt = Date()
                accountRefreshFreshness.recordSuccess(at: verifiedAt)
                accountLastSuccessfulRefresh = verifiedAt
                accountError = nil
                accountRestartStage = nil
                appendAccountOperationEvent(
                    AccountOperationEventFactory.restartSucceeded(
                        profile: profile,
                        clientDisplayName: desktopTarget.displayName
                    )
                )
                recentAccountFailureStage = nil
                refreshDiagnostics()
                if postRestartRefreshEnabled {
                    await refreshAll(refreshResetCredits: true)
                }
            case .mismatch(let expected, let actual):
                appendAccountOperationEvent(
                    AccountOperationEventFactory.restartFailed(
                        profile: expected,
                        reason: "verification_mismatch",
                        clientDisplayName: desktopTarget.displayName
                    )
                )
                recentAccountFailureStage = "verification_mismatch"
                refreshDiagnostics()
                accountRestartStage = nil
                accountError = "\(desktopTarget.displayName) 重启未通过核对：预期默认账号为 \(expected ?? "未知")，工作台状态为 \(actual ?? "未知")。"
            }
        }
    }

    private func appendAccountOperationEvent(_ event: OperationEvent) {
        let result = LedgerWriter().append(events: [event], to: ledgerURL)
        guard result.appendedCount == 1 else { return }
        events = (events + [event]).sorted { $0.occurredAt > $1.occurredAt }
    }

    private func configureOfficialRateLimitObserver() {
        guard
            AccountRuntimePolicy.officialRateLimitObservationAllowed(
                storageMode: accountPayload?.accountStorage.mode
            ),
            let profileName = desktopProfileName,
            let profileHome = accountPayload?.profiles.first(where: { $0.name == profileName })?.path
        else {
            officialRateLimitObserver.stop()
            return
        }
        officialRateLimitObserver.start(profileHome: profileHome) { [weak self] in
            Task { await self?.refreshAll(refreshResetCredits: true) }
        }
    }

    private static func developmentAccountGateway() -> AccountGateway? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return AccountBackendLocator.development(repositoryRoot: root)
    }
}
