import CodexWorkbenchCore
import Foundation

func runAccountGatewayTests(_ runner: inout TestRunner) {
    let payloadJSON = #"""
    {
      "generated_at":"2026-07-14T13:55:08.500568+00:00",
      "active_profile":"hd-master",
      "account_storage":{"mode":"unified_vault","active_account_id":"hd-master","account_count":2,"root_auth_kind":"plain_file"},
      "legacy_migration":{"available":true,"profile_count":2,"status":"completed","requires_confirmation":true},
      "runtime_status":{"state":"running","light":"green","label":"运行中","active_process_count":1,"recent_process_count":1,"latest_activity_age_ms":1200},
      "desktop_status":{"running":true,"managed":true,"state":"managed_default_home","message":"ok","active_profile":"hd-master"},
      "profile_roles":{"task":{"profile":"hd-sarah-blackwell","source":"recent_active_thread_rate_limit_match","confidence":"inferred","observed_at":1784037295,"thread_id":"019f6067-342c-7b22-a9fc-cd50ded08d86"},"desktop":{"profile":"hd-master","source":"desktop_bridge_record","confidence":"confirmed"},"attribution":{"profile":"hd-master","source":"attribution_ledger","confidence":"confirmed"},"task_matches_desktop":false},
      "attribution_summary":{"active_profile":"hd-master","managed":true},
      "local_snapshot":{"event_count":5,"latest_timestamp":"2026-07-17T08:00:00Z","total":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":140},"daily":[{"date":"2026-07-17","input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":140}],"by_model":[{"model":"gpt-5.6","input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":10,"total_tokens":140}]},
      "thread_attribution":{"schema_version":1,"source":"local_rollouts","scope_label":"本机 rollout 统计","disclaimer":"不是官方账单，也不是实时配额。","is_official_billing":false,"generated_at":"2026-07-17T08:00:00Z","rollout_count":3,"top_level_task_count":1,"metadata_missing_count":0,"metadata_malformed_count":0,"bad_line_count":0,"risk_counts":{"child_share":1,"full_context_fork":1,"data_quality":0},"tasks":[{"thread_id":"parent","status":"top_level","status_label":"顶层任务","own_tokens":{"input_tokens":100,"cached_input_tokens":40,"non_cached_input_tokens":60,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":115},"child_tokens":{"input_tokens":200,"cached_input_tokens":160,"non_cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":230},"merged_tokens":{"input_tokens":300,"cached_input_tokens":200,"non_cached_input_tokens":100,"output_tokens":30,"reasoning_output_tokens":15,"total_tokens":345},"child_task_count":1,"fork_child_count":1,"child_share":0.67,"child_share_abnormal":false,"full_context_fork_risk":true,"risk_messages":["检测到 fork 子任务的缓存输入占比较高"],"children":[{"thread_id":"child","relation":"fork","depth":1,"metadata_status":"valid","tokens":{"input_tokens":200,"cached_input_tokens":160,"non_cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":230},"rollout_count":1}],"rollout_count":2}]},
      "project_rankings":{"available":true,"projects":[{"name":"tools","path":"/safe/tools","thread_count":3,"tokens_used":1000,"latest_updated_at":1784632000}]},
      "tool_rankings":{"available":true,"tools":[{"id":"functions.exec","namespace":"functions","name":"exec","call_count":9,"latest_updated_at":1784632000,"thread_tokens":3000}]},
      "skill_rankings":{"available":true,"skills":[{"name":"brainstorming","use_count":2,"latest_timestamp":"2026-07-17T08:00:00Z"}],"bad_line_count":0},
      "profiles":[{
        "name":"hd-master",
        "path":"/Users/example/.codex/profiles/hd-master",
        "auth":"present",
        "config":"present",
        "account":{"available":true,"type":"chatgpt","plan_type":"plus","email_present":true,"requires_openai_auth":true},
        "rate_limits":{"primary":{"used_percent":13,"remaining_percent":87,"window_minutes":300,"resets_at":1784632385},"secondary":{"used_percent":38,"remaining_percent":62,"window_minutes":10080,"resets_at":1785032385},"rate_limit_reached_type":"primary","reset_credits":{"available":true,"available_count":2}},
        "reset_credit_details":{"available":true,"available_count":2,"total_earned_count":4,"earliest_expires_at":1784732385,"credits":[{"id":"masked","status":"available","used":false,"title":"额度重置","expires_at":1784732385,"reminders":[{"kind":"one_hour","at":1784728785}]}]},
        "reset_credit_stale":false,
        "reset_credit_error":null,
        "usage":{"summary":{"lifetimeTokens":50000,"peakDailyTokens":9000,"currentStreakDays":3},"dailyUsageBuckets":[{"startDate":"2026-07-16","tokens":8000},{"startDate":"2026-07-17","tokens":1234}]},
        "usage_metrics":{"today_tokens":1234,"today_available":true,"last_7_tokens":9000,"last_14_tokens":17000,"latest_date":"2026-07-17","source":"account_usage"},
        "token_attribution":{"active_profile":"hd-master","managed":true,"estimate_available":true,"today_estimated_tokens":1200,"today_official_tokens":1234,"today_display_tokens":1234,"today_source":"official"},
        "remote_stale":false,
        "remote_error":null
      }]
    }
    """#
    let decoded = try? AccountDashboardPayload.decode(data: Data(payloadJSON.utf8))
    runner.expect(decoded?.activeProfile == "hd-master", "Active profile should decode")
    runner.expect(
        decoded?.accountStorage.mode == .unifiedVault,
        "Unified account storage should decode explicitly"
    )
    runner.expect(
        decoded?.legacyMigration.profileCount == 2,
        "Legacy migration metadata should remain available after migration"
    )
    runner.expect(decoded?.desktopStatus?.running == true, "Desktop running state should decode")
    runner.expect(decoded?.profileRoles?.task.confidence == .inferred, "Task role inference should stay explicit")
    runner.expect(decoded?.profileRoles?.desktop.confidence == .confirmed, "Desktop role should stay confirmed")
    runner.expect(decoded?.profileRoles?.task.threadID == "019f6067-342c-7b22-a9fc-cd50ded08d86", "Task role should retain thread id")
    runner.expect(decoded?.runtimeStatus?.state == "running", "Runtime state should decode")
    runner.expect(decoded?.runtimeStatus?.activeProcessCount == 1, "Runtime process count should decode")
    runner.expect(decoded?.profiles.first?.account?.planType == "plus", "Account plan should decode")
    runner.expect(decoded?.profiles.first?.rateLimits.primary?.remainingPercent == 87, "Primary remaining quota should decode")
    runner.expect(decoded?.profiles.first?.rateLimits.secondary?.remainingPercent == 62, "Secondary quota should decode")
    runner.expect(decoded?.profiles.first?.rateLimits.resetCredits?.availableCount == 2, "Reset credits should decode")
    runner.expect(decoded?.profiles.first?.resetCreditDetails?.credits.count == 1, "Individual reset credits should decode")
    runner.expect(decoded?.profiles.first?.resetCreditDetails?.credits.first?.reminders?.first?.kind == "one_hour", "Reset credit reminders should decode")
    runner.expect(decoded?.profiles.first?.usageMetrics?.todayTokens == 1_234, "Account usage metrics should decode")
    runner.expect(decoded?.profiles.first?.usage?.dailyUsageBuckets?.last?.tokens == 1_234, "Daily usage buckets should decode")
    runner.expect(decoded?.profiles.first?.tokenAttribution?.todayDisplayTokens == 1_234, "Token attribution should decode")
    runner.expect(decoded?.attributionSummary?.activeProfile == "hd-master", "Attribution summary should decode")
    runner.expect(decoded?.localSnapshot?.total.totalTokens == 140, "Local token snapshot should decode")
    runner.expect(decoded?.localSnapshot?.byModel?.first?.model == "gpt-5.6", "Local model totals should decode")
    runner.expect(decoded?.threadAttribution?.topLevelTaskCount == 1, "Thread attribution should decode")
    runner.expect(decoded?.threadAttribution?.tasks.first?.mergedTokens.totalTokens == 345, "Merged thread tokens should decode")
    runner.expect(decoded?.threadAttribution?.tasks.first?.children.first?.relation == "fork", "Fork child relation should decode")
    runner.expect(decoded?.threadAttribution?.isOfficialBilling == false, "Thread attribution must stay non-official")
    runner.expect(decoded?.projectRankings?.projects.first?.threadCount == 3, "Project rankings should decode")
    runner.expect(decoded?.toolRankings?.tools.first?.callCount == 9, "Tool rankings should decode")
    runner.expect(decoded?.skillRankings?.skills.first?.useCount == 2, "Skill rankings should decode")
    runner.expect(decoded?.profiles.first?.path == "/Users/example/.codex/profiles/hd-master", "Profile home should decode for the observer")
    runner.expect(decoded?.profiles.first?.rateLimits.reachedType == "primary", "Official reached state should decode")

    var malformedPayload = try! JSONSerialization.jsonObject(
        with: Data(payloadJSON.utf8)
    ) as! [String: Any]
    malformedPayload["thread_attribution"] = ["tasks": "malformed"]
    let malformedThreadAttribution = try! JSONSerialization.data(
        withJSONObject: malformedPayload
    )
    let legacyDecoded = try? AccountDashboardPayload.decode(data: malformedThreadAttribution)
    runner.expect(legacyDecoded != nil, "Malformed optional thread attribution must not break legacy payload")
    runner.expect(legacyDecoded?.threadAttribution == nil, "Malformed optional thread attribution should degrade to unavailable")

    let frozenExecutable = URL(
        fileURLWithPath: "/Applications/Codex 工作台.app/Contents/Helpers/CodexAccountBackend/CodexAccountBackend"
    )
    let frozen = AccountCommandBuilder(executableURL: frozenExecutable, argumentPrefix: [])
    let status = frozen.statusCommand(refreshResetCredits: false)
    runner.expect(status.executableURL == frozenExecutable, "Release status must use the bundled executable")
    runner.expect(status.arguments == ["status", "--json"], "Frozen status should call the JSON contract directly")
    runner.expect(
        frozen.statusCommand(refreshResetCredits: true).arguments.last == "--refresh-reset-credits",
        "Explicit refresh should request fresh reset credits"
    )
    runner.expect(
        frozen.switchCommand(
            profile: "hd-master",
            target: DesktopClientTarget(
                appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                processIdentifier: 42,
                isRunning: true,
                selectionReason: .runningInstance
            )
        )?.arguments
            == [
                "app", "hd-master",
                "--app-path", "/Applications/ChatGPT.app",
                "--expected-pid", "42",
            ],
        "Frozen switch should preserve the exact running desktop target"
    )
    runner.expect(
        frozen.restartCommand(
            profile: "hd-master",
            allowActive: false,
            target: DesktopClientTarget(
                appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                processIdentifier: 42,
                isRunning: true,
                selectionReason: .runningInstance
            )
        )?.arguments
            == [
                "restart", "--profile", "hd-master",
                "--app-path", "/Applications/ChatGPT.app",
                "--expected-pid", "42",
            ],
        "Managed restart should preserve the profile and exact desktop identity"
    )
    runner.expect(
        frozen.restartCommand(profile: nil, allowActive: false)?.arguments == ["restart"],
        "Local restart should not invent a managed profile"
    )
    runner.expect(
        frozen.restartCommand(profile: "hd-master", allowActive: true)?.arguments
            == ["restart", "--profile", "hd-master", "--allow-active"],
        "A user-confirmed restart should carry an explicit backend override"
    )
    runner.expect(
        frozen.restartCommand(profile: "../../bad", allowActive: false) == nil,
        "Restart must reject unsafe profile names"
    )
    runner.expect(
        frozen.consumeResetCreditCommand(profile: "hd-master", idempotencyKey: "stable-key")?.arguments
            == ["consume-reset-credit", "hd-master", "--idempotency-key", "stable-key"],
        "Frozen reset consumption should reuse the sanitized command contract"
    )
    runner.expect(
        frozen.migrateProfilesCommand(dryRun: true).arguments
            == ["migrate-profiles", "--dry-run"],
        "Migration preview must be an explicit read-only command"
    )
    runner.expect(
        frozen.migrateProfilesCommand(dryRun: false).arguments
            == ["migrate-profiles"],
        "Migration execution must never be hidden inside status"
    )
    runner.expect(
        frozen.recoverVaultCommand().arguments == ["recover-vault"],
        "Vault recovery must remain an explicit guarded command"
    )
    runner.expect(
        frozen.projectCommand(["list"]).arguments == ["project", "list"],
        "Project service commands must stay under the explicit project namespace"
    )
    let managedProjectsJSON = #"{"generated_at":"2026-07-29T08:00:00Z","projects":[],"discovered_services":[],"codex_tasks":[],"browser_processes":[]}"#
    let managedGateway = AccountGateway(
        commandBuilder: frozen,
        commandRunner: { command in
            guard command.arguments == ["project", "list"] else {
                throw AccountGatewayError.invalidPayload
            }
            return Data(managedProjectsJSON.utf8)
        }
    )
    let managedProjects = try? managedGateway.loadManagedProjects()
    runner.expect(
        managedProjects?.generatedAt != nil,
        "Project-only refresh should decode the backend list payload without a full dashboard refresh"
    )
    let switchGateway = AccountGateway(
        commandBuilder: frozen,
        commandRunner: { command in
            guard command.arguments == ["project", "switch", "project-123"] else {
                throw AccountGatewayError.invalidPayload
            }
            return Data()
        }
    )
    runner.expect(
        (try? switchGateway.switchManagedProject("project-123")) != nil,
        "Switching a verified port conflict must use the explicit project switch command"
    )
    runner.expect(
        frozen.consumeResetCreditCommand(profile: "../../bad", idempotencyKey: "stable-key") == nil,
        "Reset consumption must reject unsafe profile names"
    )
    runner.expect(
        frozen.consumeResetCreditCommand(profile: "hd-master", idempotencyKey: "") == nil,
        "Reset consumption must reject an empty idempotency key"
    )
    runner.expect(frozen.switchCommand(profile: "../../bad") == nil, "Unsafe profile names must be rejected")
    runner.expect(frozen.switchCommand(profile: "name with space") == nil, "Whitespace profile names must be rejected")

    let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
    let helperURL = URL(fileURLWithPath: "/repo/Platform/LocalDataRuntime/codex_profile.py")
    let development = AccountCommandBuilder(
        executableURL: pythonURL,
        argumentPrefix: [helperURL.path],
        requiredResourceURL: helperURL
    )
    runner.expect(
        development.statusCommand(refreshResetCredits: false).arguments
            == [helperURL.path, "status", "--json"],
        "Development status should retain the source helper prefix"
    )

    let locatorRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-account-locator-\(UUID().uuidString)")
    let resourceURL = locatorRoot.appendingPathComponent("Contents/Resources", isDirectory: true)
    let bundledExecutable = locatorRoot
        .appendingPathComponent("Contents/Helpers/CodexAccountBackend", isDirectory: true)
        .appendingPathComponent("CodexAccountBackend")
    try? FileManager.default.createDirectory(
        at: bundledExecutable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bundledExecutable.path, contents: Data())
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: bundledExecutable.path
    )
    defer { try? FileManager.default.removeItem(at: locatorRoot) }

    let bundled = AccountBackendLocator.bundled(resourceURL: resourceURL)
    runner.expect(
        bundled?.commandBuilder.executableURL == bundledExecutable,
        "Release locator must resolve only the fixed bundled backend path"
    )
    runner.expect(
        bundled?.commandBuilder.argumentPrefix.isEmpty == true,
        "Release locator must not carry a Python source prefix"
    )
    runner.expect(
        AccountBackendLocator.bundled(
            resourceURL: locatorRoot.appendingPathComponent("Missing/Contents/Resources")
        ) == nil,
        "A missing bundled executable must allow the development locator to run"
    )

    let environment = AccountCommandBuilder.processEnvironment(base: ["PATH": "/custom/bin"])
    runner.expect(
        environment["PYTHONDONTWRITEBYTECODE"] == "1",
        "Bundled Python must not mutate the signed app by writing bytecode caches"
    )
    runner.expect(
        environment["PATH"]?.hasSuffix(":/custom/bin") == true,
        "Python environment should preserve the caller PATH"
    )

    let consumeJSON = #"{"ok":true,"outcome":"alreadyRedeemed","expires_at":1784335011,"error":null}"#
    let consumeResult = try? AccountResetCreditConsumeResult.decode(data: Data(consumeJSON.utf8))
    runner.expect(consumeResult?.ok == true, "Reset consumption result should decode its success state")
    runner.expect(consumeResult?.outcome == "alreadyRedeemed", "Reset outcome should preserve backend semantics")
    runner.expect(consumeResult?.expiresAt == 1_784_335_011, "Reset result should decode the selected expiry")

    let busyFailure = AccountGatewayError.processFailure(
        code: 1,
        standardError: "Codex Desktop did not quit within 12 seconds; switch aborted.\n"
    )
    runner.expect(busyFailure == .codexDesktopBusy, "Known switch preconditions should have a safe error")
    runner.expect(
        busyFailure.errorDescription?.contains("任务") == true,
        "The user should understand why Codex could not switch accounts"
    )
    let confirmationFailure = AccountGatewayError.processFailure(
        code: 3,
        standardError: "Codex restart confirmation required: waiting\n"
    )
    runner.expect(
        confirmationFailure == .restartConfirmationRequired(.waitingTask),
        "A live backend preflight should return the matching restart confirmation"
    )
    let unknownFailure = AccountGatewayError.processFailure(
        code: 42,
        standardError: "secret backend detail"
    )
    runner.expect(unknownFailure == .processFailed(42), "Unknown backend errors should retain only the exit code")
    runner.expect(
        unknownFailure.errorDescription?.contains("secret backend detail") == false,
        "Unknown stderr must never be exposed"
    )
    let recoveryFailure = AccountGatewayError.processFailure(
        code: 2,
        standardError: "an account transaction requires recovery\n"
    )
    runner.expect(
        recoveryFailure == .vaultRecoveryRequired,
        "Pending durable transactions must surface a safe recovery action"
    )
}
