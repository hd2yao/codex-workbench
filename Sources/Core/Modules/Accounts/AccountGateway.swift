import Foundation

public struct AccountCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public struct AccountCommandBuilder: Equatable, Sendable {
    public let executableURL: URL
    public let argumentPrefix: [String]
    public let requiredResourceURL: URL?

    public init(
        executableURL: URL,
        argumentPrefix: [String],
        requiredResourceURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.argumentPrefix = argumentPrefix
        self.requiredResourceURL = requiredResourceURL
    }

    public func statusCommand(refreshResetCredits: Bool) -> AccountCommand {
        var arguments = argumentPrefix + ["status", "--json"]
        if refreshResetCredits {
            arguments.append("--refresh-reset-credits")
        }
        return AccountCommand(executableURL: executableURL, arguments: arguments)
    }

    public func switchCommand(
        profile: String,
        target: DesktopClientTarget? = nil
    ) -> AccountCommand? {
        guard Self.isSafeProfileName(profile) else { return nil }
        guard let targetArguments = Self.targetArguments(target) else { return nil }
        return AccountCommand(
            executableURL: executableURL,
            arguments: argumentPrefix + ["app", profile] + targetArguments
        )
    }

    public func restartCommand(
        profile: String?,
        allowActive: Bool,
        target: DesktopClientTarget? = nil
    ) -> AccountCommand? {
        var arguments = argumentPrefix + ["restart"]
        if let profile {
            guard Self.isSafeProfileName(profile) else { return nil }
            arguments += ["--profile", profile]
        }
        guard let targetArguments = Self.targetArguments(target) else { return nil }
        arguments += targetArguments
        if allowActive {
            arguments.append("--allow-active")
        }
        return AccountCommand(executableURL: executableURL, arguments: arguments)
    }

    public func consumeResetCreditCommand(
        profile: String,
        idempotencyKey: String
    ) -> AccountCommand? {
        guard
            Self.isSafeProfileName(profile),
            Self.isSafeIdempotencyKey(idempotencyKey)
        else {
            return nil
        }
        return AccountCommand(
            executableURL: executableURL,
            arguments: argumentPrefix + [
                "consume-reset-credit",
                profile,
                "--idempotency-key",
                idempotencyKey,
            ]
        )
    }

    public func migrateProfilesCommand(dryRun: Bool) -> AccountCommand {
        var arguments = argumentPrefix + ["migrate-profiles"]
        if dryRun {
            arguments.append("--dry-run")
        }
        return AccountCommand(executableURL: executableURL, arguments: arguments)
    }

    public func recoverVaultCommand() -> AccountCommand {
        AccountCommand(
            executableURL: executableURL,
            arguments: argumentPrefix + ["recover-vault"]
        )
    }

    public func projectCommand(_ arguments: [String]) -> AccountCommand {
        AccountCommand(
            executableURL: executableURL,
            arguments: argumentPrefix + ["project"] + arguments
        )
    }

    public static func isSafeProfileName(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil
    }

    public static func isSafeIdempotencyKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 256
    }

    public static func processEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            base["PATH"] ?? "",
        ].joined(separator: ":")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    private static func targetArguments(_ target: DesktopClientTarget?) -> [String]? {
        guard let target else { return [] }
        guard target.isSafeCommandTarget else { return nil }
        var arguments = ["--app-path", target.appURL.path]
        if let processIdentifier = target.processIdentifier {
            arguments += ["--expected-pid", String(processIdentifier)]
        }
        return arguments
    }
}

public enum AccountGatewayError: Error, Equatable, LocalizedError, Sendable {
    case backendMissing
    case codexDesktopBusy
    case codexDesktopLaunchFailed
    case restartConfirmationRequired(AccountRestartConfirmationReason)
    case accountConflict
    case vaultRecoveryRequired
    case invalidProfile
    case launchFailed
    case processFailed(Int32)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .backendMissing: "账号模块不可用，请重新构建工作台。"
        case .codexDesktopBusy: "桌面客户端仍有任务正在运行，未能安全退出。请等任务结束后再切换账号。"
        case .codexDesktopLaunchFailed: "账号已准备，但桌面客户端未能重新启动。请手动打开后刷新状态。"
        case .restartConfirmationRequired(let reason):
            switch reason {
            case .runningTask: "检测到任务刚刚开始运行，请确认后再重启桌面客户端。"
            case .waitingTask: "检测到待接手任务，请确认后再重启桌面客户端。"
            case .unknownState: "无法确认最新任务状态，请确认后再重启桌面客户端。"
            }
        case .accountConflict: "检测到 Codex 认证账号意外变化。为保护两个账号，切换已中止。"
        case .vaultRecoveryRequired:
            "检测到上次账号事务尚未收敛。请退出 ChatGPT/Codex 和 Codex CLI，再执行账号库恢复。"
        case .invalidProfile: "账号名称不符合安全规则。"
        case .launchFailed: "无法启动账号模块。"
        case .processFailed(let code): "账号模块执行失败（退出码 \(code)）。"
        case .invalidPayload: "账号状态数据格式不兼容。"
        }
    }

    public static func processFailure(code: Int32, standardError: String) -> AccountGatewayError {
        if standardError.contains("Codex restart confirmation required: running") {
            return .restartConfirmationRequired(.runningTask)
        }
        if standardError.contains("Codex restart confirmation required: waiting") {
            return .restartConfirmationRequired(.waitingTask)
        }
        if standardError.contains("Codex restart confirmation required: unknown") {
            return .restartConfirmationRequired(.unknownState)
        }
        if standardError.contains("Codex Desktop did not quit within 12 seconds; switch aborted.") {
            return .codexDesktopBusy
        }
        if standardError.contains(
            "Codex auth account changed unexpectedly; switch aborted to preserve both accounts."
        ) {
            return .accountConflict
        }
        if standardError.contains(
            "Codex Desktop did not launch within 12 seconds after opening the selected app."
        ) {
            return .codexDesktopLaunchFailed
        }
        if standardError.contains("account transaction requires recovery") {
            return .vaultRecoveryRequired
        }
        return .processFailed(code)
    }
}

public struct AccountGateway: Sendable {
    public let commandBuilder: AccountCommandBuilder
    private let commandRunner: (@Sendable (AccountCommand) throws -> Data)?

    public init(
        commandBuilder: AccountCommandBuilder,
        commandRunner: (@Sendable (AccountCommand) throws -> Data)? = nil
    ) {
        self.commandBuilder = commandBuilder
        self.commandRunner = commandRunner
    }

    public func loadStatus(refreshResetCredits: Bool = false) throws -> AccountDashboardPayload {
        let data = try run(commandBuilder.statusCommand(refreshResetCredits: refreshResetCredits))
        do {
            return try AccountDashboardPayload.decode(data: data)
        } catch {
            throw AccountGatewayError.invalidPayload
        }
    }

    public func loadManagedProjects() throws -> AccountManagedProjects {
        let data = try run(commandBuilder.projectCommand(["list"]))
        do {
            return try LedgerRepository.decoder().decode(AccountManagedProjects.self, from: data)
        } catch {
            throw AccountGatewayError.invalidPayload
        }
    }

    public func switchProfile(
        _ profile: String,
        target: DesktopClientTarget? = nil
    ) throws {
        guard let command = commandBuilder.switchCommand(profile: profile, target: target) else {
            throw AccountGatewayError.invalidProfile
        }
        _ = try run(command)
    }

    public func restartCurrentAccount(
        profile: String?,
        allowActive: Bool,
        target: DesktopClientTarget? = nil
    ) throws {
        guard let command = commandBuilder.restartCommand(
            profile: profile,
            allowActive: allowActive,
            target: target
        ) else {
            throw AccountGatewayError.invalidProfile
        }
        _ = try run(command)
    }

    public func consumeResetCredit(
        profile: String,
        idempotencyKey: String
    ) throws -> AccountResetCreditConsumeResult {
        guard let command = commandBuilder.consumeResetCreditCommand(
            profile: profile,
            idempotencyKey: idempotencyKey
        ) else {
            throw AccountGatewayError.invalidProfile
        }
        let data = try run(command)
        do {
            return try AccountResetCreditConsumeResult.decode(data: data)
        } catch {
            throw AccountGatewayError.invalidPayload
        }
    }

    public func migrateLegacyProfiles(dryRun: Bool) throws -> AccountLegacyMigrationReport {
        let data = try run(commandBuilder.migrateProfilesCommand(dryRun: dryRun))
        do {
            return try LedgerRepository.decoder().decode(
                AccountLegacyMigrationReport.self,
                from: data
            )
        } catch {
            throw AccountGatewayError.invalidPayload
        }
    }

    public func recoverVault() throws {
        _ = try run(commandBuilder.recoverVaultCommand())
    }

    public func addManagedProject(
        name: String,
        cwd: String,
        command: String,
        port: Int?,
        adoptCurrent: Bool = false
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AccountGatewayError.invalidPayload
        }
        var arguments = [
            "add", "--name", name, "--cwd", cwd, "--command", command
        ]
        if let port {
            arguments += ["--port", String(port)]
        }
        if adoptCurrent {
            arguments.append("--adopt-current")
        }
        _ = try run(commandBuilder.projectCommand(arguments))
    }

    public func startManagedProject(_ id: String) throws {
        guard Self.isSafeProjectIdentifier(id) else {
            throw AccountGatewayError.invalidPayload
        }
        _ = try run(commandBuilder.projectCommand(["start", id]))
    }

    public func switchManagedProject(_ id: String) throws {
        guard Self.isSafeProjectIdentifier(id) else {
            throw AccountGatewayError.invalidPayload
        }
        _ = try run(commandBuilder.projectCommand(["switch", id]))
    }

    public func stopManagedProject(_ id: String) throws {
        guard Self.isSafeProjectIdentifier(id) else {
            throw AccountGatewayError.invalidPayload
        }
        _ = try run(commandBuilder.projectCommand(["stop", id]))
    }

    public func removeManagedProject(_ id: String) throws {
        guard Self.isSafeProjectIdentifier(id) else {
            throw AccountGatewayError.invalidPayload
        }
        _ = try run(commandBuilder.projectCommand(["remove", id]))
    }

    public func pruneDuplicateManagedProjects() throws {
        _ = try run(commandBuilder.projectCommand(["prune-duplicates"]))
    }

    public func stopManagedProcess(pid: Int, fingerprint: String) throws {
        guard pid > 0, fingerprint.range(of: #"^[a-f0-9]{16}$"#, options: .regularExpression) != nil else {
            throw AccountGatewayError.invalidPayload
        }
        _ = try run(
            commandBuilder.projectCommand([
                "stop-process", "--pid", String(pid), "--fingerprint", fingerprint
            ])
        )
    }

    private static func isSafeProjectIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{8,128}$"#, options: .regularExpression) != nil
    }

    private func run(_ command: AccountCommand) throws -> Data {
        if let commandRunner {
            return try commandRunner(command)
        }
        guard FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
            throw AccountGatewayError.backendMissing
        }
        if let requiredResourceURL = commandBuilder.requiredResourceURL,
           !FileManager.default.fileExists(atPath: requiredResourceURL.path) {
            throw AccountGatewayError.backendMissing
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = output
        process.standardError = errorOutput
        process.environment = AccountCommandBuilder.processEnvironment(
            base: ProcessInfo.processInfo.environment
        )

        do {
            try process.run()
        } catch {
            throw AccountGatewayError.launchFailed
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let standardError = String(data: errorData, encoding: .utf8) ?? ""
            throw AccountGatewayError.processFailure(
                code: process.terminationStatus,
                standardError: standardError
            )
        }
        return data
    }
}

public enum AccountBackendLocator {
    public static func bundled(resourceURL: URL? = Bundle.main.resourceURL) -> AccountGateway? {
        guard let resourceURL else { return nil }
        let executableURL = resourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CodexAccountBackend", isDirectory: true)
            .appendingPathComponent("CodexAccountBackend")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return AccountGateway(
            commandBuilder: AccountCommandBuilder(
                executableURL: executableURL,
                argumentPrefix: []
            )
        )
    }

    public static func development(repositoryRoot: URL) -> AccountGateway? {
        let helperURL = repositoryRoot
            .appendingPathComponent("Platform/LocalDataRuntime", isDirectory: true)
            .appendingPathComponent("codex_profile.py")
        guard let pythonURL = resolvePython() else { return nil }
        return AccountGateway(
            commandBuilder: AccountCommandBuilder(
                executableURL: pythonURL,
                argumentPrefix: [helperURL.path],
                requiredResourceURL: helperURL
            )
        )
    }

    private static func resolvePython() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
