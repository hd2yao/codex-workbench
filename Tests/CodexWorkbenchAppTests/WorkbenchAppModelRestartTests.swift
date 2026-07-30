import CodexWorkbenchCore
import Foundation

private final class AppTestRunner {
    private(set) var failures = 0

    func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !condition() else { return }
        failures += 1
        fputs("FAIL: \(file):\(line): \(message)\n", stderr)
    }
}

private final class RestartGatewayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var restartOutcomes: [Result<Data, AccountGatewayError>]
    private let statusData: Data
    private let onSuccessfulRestart: (@Sendable () -> Void)?
    private var commands: [AccountCommand] = []

    init(
        restartOutcomes: [Result<Data, AccountGatewayError>],
        statusData: Data,
        onSuccessfulRestart: (@Sendable () -> Void)? = nil
    ) {
        self.restartOutcomes = restartOutcomes
        self.statusData = statusData
        self.onSuccessfulRestart = onSuccessfulRestart
    }

    func run(_ command: AccountCommand) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        commands.append(command)
        if command.arguments.contains("status") {
            return statusData
        }
        guard !restartOutcomes.isEmpty else {
            throw AccountGatewayError.processFailed(99)
        }
        let outcome = restartOutcomes.removeFirst()
        if case .success = outcome {
            onSuccessfulRestart?()
        }
        return try outcome.get()
    }

    func capturedArguments() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands.map(\.arguments)
    }
}

private final class RestartProbe: CodexAppProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var appURL: URL
    private var processIdentifier: Int32?

    init(
        appURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        processIdentifier: Int32? = 42
    ) {
        self.appURL = appURL
        self.processIdentifier = processIdentifier
    }

    func set(appURL: URL, processIdentifier: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.appURL = appURL
        self.processIdentifier = processIdentifier
    }

    func probe() -> CodexAppProbeResult {
        lock.lock()
        defer { lock.unlock() }
        return CodexAppProbeResult(
            installations: [
                DiagnosticAppInstallation(
                    url: appURL,
                    bundleIdentifier: CodexIntegration.bundleIdentifier,
                    version: "1",
                    isRunning: processIdentifier != nil,
                    processIdentifier: processIdentifier
                )
            ],
            selectedAppURL: appURL
        )
    }
}

@main
private struct WorkbenchAppModelRestartTests {
    @MainActor
    static func main() async {
        let runner = AppTestRunner()
        await liveRejectionAndConfirmedRetry(runner)
        cancellation(runner)
        await successfulRestart(runner)
        await verificationMismatch(runner)
        await processIdentityMismatch(runner)
        await legacySwitcherBlocksMigration(runner)
        defaultHomeAvailability(runner)
        guard runner.failures == 0 else { exit(1) }
        print("PASS: CodexWorkbenchAppTests")
    }

    @MainActor
    private static func liveRejectionAndConfirmedRetry(_ runner: AppTestRunner) async {
        let recorder = RestartGatewayRecorder(
            restartOutcomes: [
                .failure(.restartConfirmationRequired(.runningTask)),
                .failure(.codexDesktopLaunchFailed),
            ],
            statusData: payloadData(active: "hd-master", runtime: "running")
        )
        guard let fixture = try? makeModel(recorder: recorder, runtime: "idle") else {
            runner.expect(false, "Could not create rejection fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.requestRestartCurrentCodex()
        let rejectionObserved = await waitUntil {
            fixture.model.accountRestartConfirmation == .runningTask
                && fixture.model.accountRestartStage == nil
        }
        runner.expect(
            rejectionObserved,
            "A live backend rejection should restore the confirmation state"
        )
        runner.expect(
            recorder.capturedArguments().first
                == [
                    "restart", "--profile", "hd-master",
                    "--app-path", "/Applications/ChatGPT.app",
                    "--expected-pid", "42",
                ],
            "The first restart attempt must not carry an active-work override"
        )

        fixture.model.confirmRestartCurrentCodex()
        let confirmedFailureObserved = await waitUntil {
            fixture.model.accountRestartStage == nil
                && fixture.model.accountError?.contains("未能重新启动") == true
        }
        runner.expect(
            confirmedFailureObserved,
            "A confirmed retry should surface a later launch failure"
        )
        runner.expect(
            fixture.model.accountErrorNoticeTitle == "账号操作未完成"
                && fixture.model.dataHealthPresentation.level != .unavailable,
            "A restart failure must not be mislabeled as an unavailable account data source"
        )
        runner.expect(
            recorder.capturedArguments().dropFirst().first
                == [
                    "restart", "--profile", "hd-master",
                    "--app-path", "/Applications/ChatGPT.app",
                    "--expected-pid", "42",
                    "--allow-active",
                ],
            "Only the confirmed retry may carry --allow-active"
        )
    }

    @MainActor
    private static func cancellation(_ runner: AppTestRunner) {
        let recorder = RestartGatewayRecorder(
            restartOutcomes: [],
            statusData: payloadData(active: "hd-master", runtime: "running")
        )
        guard let fixture = try? makeModel(recorder: recorder, runtime: "running") else {
            runner.expect(false, "Could not create cancellation fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.requestRestartCurrentCodex()
        runner.expect(
            fixture.model.accountRestartConfirmation == .runningTask,
            "Cached running work should ask for confirmation"
        )
        fixture.model.cancelRestartCurrentCodex()
        runner.expect(
            fixture.model.accountRestartConfirmation == nil,
            "Cancellation should clear the confirmation state"
        )
        runner.expect(
            fixture.model.events.first?.action == "restart_cancelled",
            "Cancellation should append a skipped operation event"
        )
        runner.expect(
            recorder.capturedArguments().isEmpty,
            "Cancellation must not execute the backend"
        )
    }

    @MainActor
    private static func successfulRestart(_ runner: AppTestRunner) async {
        let probe = RestartProbe()
        let recorder = RestartGatewayRecorder(
            restartOutcomes: [.success(Data())],
            statusData: payloadData(active: "hd-master", runtime: "idle"),
            onSuccessfulRestart: {
                probe.set(
                    appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                    processIdentifier: 99
                )
            }
        )
        guard let fixture = try? makeModel(
            recorder: recorder,
            runtime: "idle",
            probe: probe
        ) else {
            runner.expect(false, "Could not create success fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.requestRestartCurrentCodex()
        let successObserved = await waitUntil {
            fixture.model.accountRestartStage == nil
                && fixture.model.events.contains { $0.action == "account_restarted" }
        }
        runner.expect(
            successObserved,
            "A verified restart should append a success event"
        )
        runner.expect(
            fixture.model.events.first {
                $0.action == "account_restarted"
            }?.title == "已重启 ChatGPT",
            "AppModel should preserve the frozen exact client name in restart events"
        )
        runner.expect(fixture.model.accountError == nil, "A verified restart should clear errors")
        runner.expect(
            fixture.model.currentProfileName == "hd-master",
            "A verified restart should keep the current account"
        )
    }

    @MainActor
    private static func verificationMismatch(_ runner: AppTestRunner) async {
        let probe = RestartProbe()
        let recorder = RestartGatewayRecorder(
            restartOutcomes: [.success(Data())],
            statusData: payloadData(active: "hd-other", runtime: "idle"),
            onSuccessfulRestart: {
                probe.set(
                    appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                    processIdentifier: 99
                )
            }
        )
        guard let fixture = try? makeModel(
            recorder: recorder,
            runtime: "idle",
            probe: probe
        ) else {
            runner.expect(false, "Could not create mismatch fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.requestRestartCurrentCodex()
        let mismatchObserved = await waitUntil {
            fixture.model.accountRestartStage == nil
                && fixture.model.events.contains { $0.action == "account_restart_failed" }
        }
        runner.expect(
            mismatchObserved,
            "A verification mismatch should append a failure event"
        )
        runner.expect(
            fixture.model.accountError?.contains("工作台状态为 hd-other") == true,
            "A mismatch should explain the observed account"
        )
    }

    @MainActor
    private static func processIdentityMismatch(_ runner: AppTestRunner) async {
        let probe = RestartProbe()
        let recorder = RestartGatewayRecorder(
            restartOutcomes: [.success(Data())],
            statusData: payloadData(active: "hd-master", runtime: "idle"),
            onSuccessfulRestart: {
                probe.set(
                    appURL: URL(fileURLWithPath: "/Applications/Codex.app"),
                    processIdentifier: 99
                )
            }
        )
        guard let fixture = try? makeModel(
            recorder: recorder,
            runtime: "idle",
            probe: probe
        ) else {
            runner.expect(false, "Could not create process identity fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.requestRestartCurrentCodex()
        let mismatchObserved = await waitUntil {
            fixture.model.accountRestartStage == nil
                && fixture.model.events.contains { $0.action == "account_restart_failed" }
        }
        runner.expect(
            mismatchObserved,
            "A correct account payload must not hide a desktop process identity mismatch"
        )
        runner.expect(
            fixture.model.accountError?.contains("桌面客户端身份") == true,
            "The process identity mismatch must remain actionable"
        )
    }

    @MainActor
    private static func legacySwitcherBlocksMigration(_ runner: AppTestRunner) async {
        let recorder = RestartGatewayRecorder(
            restartOutcomes: [],
            statusData: legacyPayloadData()
        )
        guard let fixture = try? makeModel(
            recorder: recorder,
            runtime: "idle",
            probe: RestartProbe(processIdentifier: nil),
            legacyProfileSwitcherRunning: true,
            payloadOverride: legacyPayloadData()
        ) else {
            runner.expect(false, "Could not create legacy-switcher migration fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.requestLegacyProfileMigration()
        try? await Task.sleep(for: .milliseconds(100))
        runner.expect(
            recorder.capturedArguments().isEmpty,
            "A running cold-backup Profile Switcher must block migration commands"
        )
        runner.expect(
            !fixture.model.isMigratingLegacyProfiles,
            "Blocked migration must not expose an in-progress state"
        )
    }

    @MainActor
    private static func makeModel(
        recorder: RestartGatewayRecorder,
        runtime: String,
        probe: RestartProbe = RestartProbe(),
        legacyProfileSwitcherRunning: Bool = false,
        payloadOverride: Data? = nil
    ) throws -> (model: WorkbenchAppModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-app-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gateway = AccountGateway(
            commandBuilder: AccountCommandBuilder(
                executableURL: URL(fileURLWithPath: "/test/CodexAccountBackend"),
                argumentPrefix: []
            ),
            commandRunner: { [recorder] command in
                try recorder.run(command)
            }
        )
        let payload = try AccountDashboardPayload.decode(
            data: payloadOverride
                ?? payloadData(active: "hd-master", runtime: runtime)
        )
        return (
            WorkbenchAppModel(
                testingGateway: gateway,
                payload: payload,
                ledgerURL: root.appendingPathComponent("events.jsonl"),
                desktopAppProbe: probe,
                testingLegacyProfileSwitcherRunning: legacyProfileSwitcherRunning
            ),
            root
        )
    }

    @MainActor
    private static func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func payloadData(active: String, runtime: String) -> Data {
        Data(
            """
            {
              "generated_at":"2026-07-21T04:00:00Z",
              "account_mode":"managed_profiles",
              "active_profile":"\(active)",
              "runtime_status":{"state":"\(runtime)","light":"green","label":"运行状态","active_process_count":1,"recent_process_count":1},
              "desktop_status":{"running":true,"managed":true,"state":"managed_default_home","active_profile":"\(active)"},
              "profiles":[{"name":"\(active)","path":"/tmp/\(active)","auth":"present","config":"present","account":{"available":true,"type":"chatgpt"},"rate_limits":{}}]
            }
            """.utf8
        )
    }

    private static func legacyPayloadData() -> Data {
        Data(
            """
            {
              "generated_at":"2026-07-25T04:00:00Z",
              "account_mode":"managed_profiles",
              "active_profile":"hd-master",
              "runtime_status":{"state":"idle","light":"green","label":"空闲","active_process_count":0,"recent_process_count":0},
              "desktop_status":{"running":false,"managed":true,"state":"managed_default_home","active_profile":"hd-master"},
              "account_storage":{"mode":"legacy_profiles","active_account_id":"hd-master","account_count":2,"root_auth_kind":"symlink"},
              "legacy_migration":{"available":true,"profile_count":2,"status":"available","requires_confirmation":true},
              "profiles":[{"name":"hd-master","path":"/tmp/hd-master","auth":"present","config":"present","account":{"available":true,"type":"chatgpt"},"rate_limits":{}}]
            }
            """.utf8
        )
    }

    private static func defaultHomeAvailability(_ runner: AppTestRunner) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("workbench-default-home-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        runner.expect(
            !AccountRuntimeServices.defaultAccountHomeAvailable(
                homeURL: root,
                fileManager: fileManager
            ),
            "A missing default home should be unavailable"
        )
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try? fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        runner.expect(
            !AccountRuntimeServices.defaultAccountHomeAvailable(
                homeURL: root,
                fileManager: fileManager
            ),
            "An empty default home should not imply an available account"
        )
        try? Data("{}".utf8).write(to: codexHome.appendingPathComponent("auth.json"))
        runner.expect(
            AccountRuntimeServices.defaultAccountHomeAvailable(
                homeURL: root,
                fileManager: fileManager
            ),
            "A readable auth entry should make the default account home available"
        )
    }
}
