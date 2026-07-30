import CodexWorkbenchCore
import Foundation

func runAccountPresentationTests(_ runner: inout TestRunner) {
    let payloadJSON = #"""
    {
      "generated_at":"2026-07-17T08:00:00Z",
      "active_profile":"hd-master",
      "runtime_status":{"state":"running","light":"green","label":"运行中","active_process_count":1,"recent_process_count":1,"latest_activity_age_ms":1200},
      "desktop_status":{"running":true,"managed":true,"state":"managed_default_home","message":"ok","active_profile":"hd-master"},
      "profile_roles":{"task":{"profile":"hd-sarah-blackwell","source":"recent_active_thread_rate_limit_match","confidence":"inferred"},"desktop":{"profile":"hd-master","source":"desktop_bridge_record","confidence":"confirmed"},"attribution":{"profile":"hd-sarah-blackwell","source":"attribution_ledger","confidence":"confirmed"},"task_matches_desktop":false},
      "profiles":[
        {"name":"hd-master","auth":"present","config":"present","rate_limits":{"primary":{"remaining_percent":87,"window_minutes":300},"secondary":{"remaining_percent":62,"window_minutes":10080}}},
        {"name":"hd-sarah-blackwell","auth":"present","config":"present","rate_limits":{"primary":{"remaining_percent":100,"window_minutes":300}}}
      ]
    }
    """#
    let payload = try? AccountDashboardPayload.decode(data: Data(payloadJSON.utf8))
    let presentation = AccountPresentationBuilder.menu(payload: payload)

    runner.expect(payload?.accountMode == .managedProfiles, "Legacy payloads must infer managed profile mode")
    runner.expect(
        payload?.accountStorage.mode == .legacyProfiles,
        "Legacy payloads must infer legacy storage without breaking decoding"
    )
    runner.expect(
        AccountPresentationBuilder.storage(payload: payload).canMigrateLegacyProfiles,
        "Legacy storage should expose the explicit migration action"
    )
    runner.expect(presentation.profile == "hd-master", "Menu bar must use the actual active profile")
    runner.expect(presentation.profileDisplayName == "master", "Menu bar should use the compact profile name")
    runner.expect(presentation.quotaText == "87%", "Menu bar should show the active profile primary quota")
    runner.expect(presentation.secondaryQuotaText == "62%", "Popover should show the active profile weekly quota")
    runner.expect(presentation.secondaryQuotaWindowLabel == "7日剩余", "Weekly quota should keep its window label")
    runner.expect(presentation.resetCreditText == "--", "Missing reset credit data must stay unknown")
    runner.expect(presentation.runtimeLabel == "运行中", "Menu bar should show the shared runtime state")
    runner.expect(presentation.runtimeSymbol == "bolt.circle.fill", "Running state should have a non-color symbol")
    runner.expect(
        presentation.accessibilityLabel == "预期桌面默认账号 hd-master，5小时剩余 87%，Codex 运行中",
        "Menu status should expose account, quota window, value, and runtime"
    )

    let managedProjectsJSON = #"""
    {
      "generated_at":"2026-07-29T08:00:00Z",
      "profiles":[],
      "managed_projects":{
        "generated_at":"2026-07-29T08:00:00Z",
        "projects":[{
          "id":"project-12345678",
          "name":"GEO 前端",
          "cwd":"/tmp/geo",
          "command":"npm run dev -- --port 5173",
          "port":5173,
          "pid":1234,
          "pgid":1234,
          "state":"running",
          "state_label":"运行中",
          "can_start":false,
          "can_stop":true,
          "port_listening":true
        }],
        "discovered_services":[{
          "id":"discovered-1",
          "name":"frontend",
          "source":"codex_task",
          "source_task_ids":["task-1"],
          "cwd":"/tmp/frontend",
          "command":"npm run dev -- --port 5173",
          "port":5173,
          "state":"listening",
          "state_label":"当前监听",
          "port_listening":true,
          "port_owner_pid":1234,
          "port_owner_command":"node",
          "can_register":true,
          "reason":"来自 Codex 任务记录，可登记为项目服务",
          "last_seen_at_ms":1000
        }],
        "codex_tasks":[{
          "id":"task-12345678",
          "task_id":"conversation-1",
          "command":"npm run dev -- --port 5173",
          "state":"running_by_port",
          "state_label":"端口仍在监听",
          "kind":"task_process",
          "related_ports":[5173],
          "can_stop":false
        }],
        "browser_processes":[],
        "errors":{"processes":null,"ports":null}
      }
    }
    """#
    let managedPayload = try? AccountDashboardPayload.decode(data: Data(managedProjectsJSON.utf8))
    runner.expect(
        managedPayload?.managedProjects?.projects.first?.port == 5173
            && managedPayload?.managedProjects?.projects.first?.canStop == true,
        "Managed project payload must preserve port and safe stop state"
    )
    runner.expect(
        managedPayload?.managedProjects?.discoveredServices.first?.port == 5173
            && managedPayload?.managedProjects?.discoveredServices.first?.canRegister == true,
        "Discovered Codex services must preserve registerable port evidence"
    )
    runner.expect(
        managedPayload?.managedProjects?.codexTasks.first?.relatedPorts == [5173],
        "Codex task payload must preserve related project ports"
    )

    let unknown = AccountPresentationBuilder.menu(payload: nil)
    runner.expect(unknown.quotaText == "--", "Unknown quota must not be shown as zero")
    runner.expect(unknown.runtimeLabel == "未知", "Missing runtime must stay unknown")

    let inconsistentJSON = #"""
    {
      "generated_at":"2026-07-17T08:00:00Z",
      "active_profile":"hd-master",
      "desktop_status":{"running":true,"managed":true,"state":"managed_default_home","active_profile":"hd-sarah-blackwell"},
      "profiles":[
        {"name":"hd-master","auth":"present","config":"present","rate_limits":{"primary":{"remaining_percent":87,"window_minutes":300}}},
        {"name":"hd-sarah-blackwell","auth":"present","config":"present","rate_limits":{"primary":{"remaining_percent":42,"window_minutes":300}}}
      ]
    }
    """#
    let inconsistentPayload = try? AccountDashboardPayload.decode(data: Data(inconsistentJSON.utf8))
    let inconsistent = AccountPresentationBuilder.menu(payload: inconsistentPayload)
    runner.expect(inconsistent.profile == nil, "Mismatched auth and desktop records must not invent a current account")
    runner.expect(inconsistent.quotaText == "--", "Mismatched account state must not show either account's quota as current")

    let unmanagedJSON = #"""
    {
      "generated_at":"2026-07-17T08:00:00Z",
      "active_profile":"hd-master",
      "desktop_status":{"running":true,"managed":false,"state":"manual_or_unknown","active_profile":"hd-master"},
      "profiles":[{"name":"hd-master","auth":"present","config":"present","rate_limits":{"primary":{"remaining_percent":87,"window_minutes":300}}}]
    }
    """#
    let unmanagedPayload = try? AccountDashboardPayload.decode(data: Data(unmanagedJSON.utf8))
    runner.expect(
        AccountPresentationBuilder.menu(payload: unmanagedPayload).profile == nil,
        "An unmanaged desktop session must remain unknown even when its stale record matches"
    )

    let localDefaultJSON = #"""
    {
      "generated_at":"2026-07-20T06:00:00Z",
      "account_mode":"local_default",
      "active_profile":"local-default",
      "runtime_status":{"state":"idle","light":"red","label":"空闲","active_process_count":0,"recent_process_count":0},
      "desktop_status":{"running":false,"managed":false,"state":"local_default","message":"使用本机默认 Codex 账号","active_profile":"local-default"},
      "profiles":[
        {"name":"local-default","path":"/tmp/.codex","auth":"present","config":"present","account":{"available":true,"type":"chatgpt"},"rate_limits":{"primary":{"remaining_percent":43,"window_minutes":300}}}
      ]
    }
    """#
    let localPayload = try? AccountDashboardPayload.decode(data: Data(localDefaultJSON.utf8))
    let localMenu = AccountPresentationBuilder.menu(payload: localPayload)
    let localDetails = AccountPresentationBuilder.details(payload: localPayload)
    runner.expect(localPayload?.accountMode == .localDefault, "Local default mode must decode")
    runner.expect(
        localPayload?.accountStorage.mode == .localDefault,
        "Old local payloads must infer local storage"
    )
    runner.expect(
        AccountPresentationBuilder.confirmedCurrentProfileName(payload: localPayload) == "local-default",
        "The default home account is confirmed by its explicit mode"
    )
    runner.expect(
        localMenu.profileDisplayName == "本机当前账号",
        "Synthetic internal keys must not leak into the menu"
    )
    runner.expect(localMenu.quotaText == "43%", "Local mode should present the default account quota")
    runner.expect(
        !localMenu.accessibilityLabel.contains("local-default"),
        "Synthetic account keys must not leak into accessibility text"
    )
    runner.expect(
        localDetails.otherProfiles.isEmpty,
        "Local mode must not expose a switch target"
    )

    let unconfirmedLocalJSON = localDefaultJSON.replacingOccurrences(
        of: "\"available\":true",
        with: "\"available\":false"
    )
    let unconfirmedLocalPayload = try? AccountDashboardPayload.decode(
        data: Data(unconfirmedLocalJSON.utf8)
    )
    runner.expect(
        AccountPresentationBuilder.confirmedCurrentProfileName(payload: unconfirmedLocalPayload) == nil,
        "A local auth file without a confirmed App Server account must not become the current account"
    )

    let unknownModeJSON = localDefaultJSON.replacingOccurrences(
        of: "\"local_default\"",
        with: "\"future_mode\""
    )
    let unknownModePayload = try? AccountDashboardPayload.decode(data: Data(unknownModeJSON.utf8))
    runner.expect(
        unknownModePayload?.accountMode == .unavailable,
        "Unknown backend modes must fail closed without breaking payload decoding"
    )
    runner.expect(
        AccountPresentationBuilder.confirmedCurrentProfileName(payload: unknownModePayload) == nil,
        "Unknown account modes must not confirm a current account"
    )

    let unifiedJSON = payloadJSON.replacingOccurrences(
        of: "\"active_profile\":\"hd-master\",",
        with: """
        "active_profile":"hd-master",
        "account_storage":{"mode":"unified_vault","active_account_id":"hd-master","account_count":2,"root_auth_kind":"plain_file"},
        "legacy_migration":{"available":true,"profile_count":2,"status":"completed","requires_confirmation":true},
        """
    )
    let unifiedPayload = try? AccountDashboardPayload.decode(data: Data(unifiedJSON.utf8))
    let unifiedStorage = AccountPresentationBuilder.storage(payload: unifiedPayload)
    runner.expect(
        unifiedStorage.title == "统一账号库",
        "Unified storage should use product-facing account language"
    )
    runner.expect(
        !unifiedStorage.canMigrateLegacyProfiles,
        "Completed unified storage must not offer a second migration"
    )

    let running = AccountPresentationBuilder.runtime(
        status: AccountRuntimeStatus(
            state: "running",
            light: "red",
            label: "空闲",
            activeProcessCount: 2,
            recentProcessCount: 2
        )
    )
    runner.expect(running.label == "运行中", "Runtime state should be the canonical status source")
    runner.expect(running.symbol == "bolt.circle.fill", "Running should have a distinct symbol")
    runner.expect(running.detail == "2 个对话进程正在运行", "Running detail should include the active count")

    let recentOutput = AccountPresentationBuilder.runtime(
        status: AccountRuntimeStatus(
            state: "running",
            light: "green",
            label: "运行中",
            activeProcessCount: 0,
            recentProcessCount: 1
        )
    )
    runner.expect(recentOutput.detail == "最近 90 秒内有 Codex 输出", "Recent output should remain running")

    let waiting = AccountPresentationBuilder.runtime(
        status: AccountRuntimeStatus(
            state: "waiting",
            light: "yellow",
            label: "待接手",
            activeProcessCount: 0,
            recentProcessCount: 1
        )
    )
    runner.expect(waiting.label == "待接手", "Waiting state should keep the existing product wording")
    runner.expect(waiting.symbol == "pause.circle.fill", "Waiting should not rely on color alone")
    runner.expect(waiting.detail == "最近 15 分钟内有活动，可能等你继续", "Waiting should explain the next action")

    let idle = AccountPresentationBuilder.runtime(
        status: AccountRuntimeStatus(
            state: "idle",
            light: "red",
            label: "空闲",
            activeProcessCount: 0,
            recentProcessCount: 0
        )
    )
    runner.expect(idle.label == "空闲", "Idle state should remain explicit")
    runner.expect(idle.symbol == "circle", "Idle should have a non-color symbol")
    runner.expect(idle.detail == "当前没有运行中的对话", "Idle detail should not imply the app is closed")

    let missingRuntime = AccountPresentationBuilder.runtime(status: nil)
    runner.expect(missingRuntime.label == "未知", "Missing runtime should stay unknown")
    runner.expect(missingRuntime.symbol == "questionmark.circle", "Unknown should have an explicit symbol")

    runner.expect(
        AccountPresentationBuilder.usageSourceLabel("account_usage") == "官方账号用量",
        "Internal source identifiers should be translated for the account page"
    )
    runner.expect(
        AccountPresentationBuilder.usageSourceLabel("future_backend") == "账号统计",
        "Unknown source identifiers should not leak into the user interface"
    )
    runner.expect(
        AccountPresentationBuilder.quotaWindowName(minutes: 300) == "5 小时"
            && AccountPresentationBuilder.quotaWindowName(minutes: 10_080) == "7 日",
        "Quota window names should follow the official duration"
    )
    runner.expect(
        AccountPresentationBuilder.quotaWindowName(minutes: nil) == nil,
        "Missing window metadata must not be guessed"
    )
}
