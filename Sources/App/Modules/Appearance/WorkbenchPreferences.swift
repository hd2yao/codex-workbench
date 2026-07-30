import CodexWorkbenchCore
import ServiceManagement
import SwiftUI

enum WorkbenchPreferences {
    static let showWhenCodexLaunchesKey = "showWhenCodexLaunches"

    static var shouldShowWhenCodexLaunches: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showWhenCodexLaunchesKey) != nil else { return true }
        return defaults.bool(forKey: showWhenCodexLaunchesKey)
    }
}

@MainActor
enum WorkbenchLoginItemManager {
    static var service: SMAppService {
        SMAppService.loginItem(identifier: WorkbenchBundleContract.loginHelperIdentifier)
    }

    static var isEnabled: Bool {
        service.status == .enabled || service.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if service.status == .notRegistered {
                try service.register()
            }
            if service.status == .enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } else {
            if service.status != .notRegistered {
                try service.unregister()
            }
            if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    static func migrateLegacyRegistrationIfNeeded() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            if service.status == .notRegistered {
                try service.register()
            }
            if service.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Keep the working legacy registration if the helper cannot be enabled.
        }
    }
}

struct WorkbenchSettingsView: View {
    @AppStorage(WorkbenchPreferences.showWhenCodexLaunchesKey)
    private var showWhenCodexLaunches = true
    @AppStorage(WorkbenchAppearancePreference.defaultsKey)
    private var appearanceRawValue = WorkbenchAppearancePreference.system.rawValue

    @State private var startAtLogin = WorkbenchLoginItemManager.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("外观") {
                Picker("工作台外观", selection: $appearanceRawValue) {
                    ForEach(WorkbenchAppearancePreference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceRawValue) { newValue in
                    WorkbenchThemeController.apply(
                        WorkbenchAppearancePreference.persisted(newValue)
                    )
                }
                Text("“跟随系统”会随 macOS 的浅色或深色外观自动变化。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("启动关联") {
                Toggle(
                    "打开 ChatGPT/Codex 时显示工作台",
                    isOn: $showWhenCodexLaunches
                )
                Toggle("登录 Mac 时启动工作台", isOn: startAtLoginBinding)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("说明") {
                Text("登录启动让菜单栏入口始终可用；Codex 启动关联只负责显示工作台，不会改变账号或任务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 420)
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { startAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try WorkbenchLoginItemManager.setEnabled(true)
                    } else {
                        try WorkbenchLoginItemManager.setEnabled(false)
                    }
                    startAtLogin = WorkbenchLoginItemManager.isEnabled
                    loginItemError = nil
                } catch {
                    startAtLogin = WorkbenchLoginItemManager.isEnabled
                    loginItemError = "无法更新登录启动设置：\(error.localizedDescription)"
                }
            }
        )
    }
}
