import CodexWorkbenchCore
import SwiftUI

@main
struct CodexWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkbenchAppModel()

    init() {
        let visualConfiguration = WorkbenchVisualAcceptanceConfiguration.parse(
            environment: ProcessInfo.processInfo.environment
        )
        if WorkbenchStartupPolicy.shouldMigrateLoginItem(configuration: visualConfiguration) {
            WorkbenchLoginItemManager.migrateLegacyRegistrationIfNeeded()
        }
    }

    var body: some Scene {
        mainWindow

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            WorkbenchSettingsView()
        }
    }

    private var mainWindow: some Scene {
        Window("Codex 工作台", id: model.windowSceneID) {
            mainWindowContent
                .task { model.bootstrap() }
        }
        .defaultSize(width: WorkbenchLayout.defaultWidth, height: WorkbenchLayout.defaultHeight)
        .windowResizability(.contentMinSize)
    }

    @ViewBuilder
    private var mainWindowContent: some View {
        if model.visualAcceptanceSurface == .menu {
            MenuBarVisualAcceptancePreview(model: model)
        } else {
            WorkbenchShell(model: model)
                .frame(
                    minWidth: WorkbenchLayout.minimumWidth,
                    minHeight: WorkbenchLayout.minimumContentHeight
                )
        }
    }
}

private struct MenuBarVisualAcceptancePreview: View {
    @ObservedObject var model: WorkbenchAppModel

    var body: some View {
        MenuBarView(model: model)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
            .padding(20)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = AccountPresentationBuilder.menu(payload: model.accountPayload)
        HStack(spacing: 4) {
            Image(systemName: presentation.runtimeSymbol)
            Text(presentation.quotaText)
                .monospacedDigit()
        }
        .accessibilityLabel(presentation.accessibilityLabel)
        .onReceive(NotificationCenter.default.publisher(for: .workbenchReopenRequested)) { _ in
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
