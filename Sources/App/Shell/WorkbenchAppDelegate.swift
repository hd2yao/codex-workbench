import AppKit
import CodexWorkbenchCore

extension Notification.Name {
    static let workbenchReopenRequested = Notification.Name("WorkbenchReopenRequested")
}

final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
    private let launchMode = WorkbenchLaunchPolicy.mode(
        arguments: ProcessInfo.processInfo.arguments
    )
    private let visualAcceptanceConfiguration = WorkbenchVisualAcceptanceConfiguration.parse(
        environment: ProcessInfo.processInfo.environment
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        WorkbenchThemeController.applyPersistedPreference()
        switch visualAcceptanceConfiguration.appearance {
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case nil:
            break
        }
        if launchMode == .menuBarOnly {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureVisualAcceptanceWindowIfNeeded()
        guard launchMode == .menuBarOnly else { return }
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.title == "Codex 工作台" }
                .forEach { $0.orderOut(nil) }
        }
    }

    private func configureVisualAcceptanceWindowIfNeeded() {
        guard visualAcceptanceConfiguration.fixture != nil else { return }
        let surface = visualAcceptanceConfiguration.surface
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = NSApp.windows.first(where: { $0.title == "Codex 工作台" }) else {
                return
            }
            if surface == .menu {
                window.styleMask = [.borderless]
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.setFrame(
                    NSRect(origin: window.frame.origin, size: NSSize(width: 400, height: 520)),
                    display: true
                )
            } else {
                window.setFrame(
                    NSRect(origin: window.frame.origin, size: NSSize(width: 1_160, height: 780)),
                    display: true
                )
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.post(name: .workbenchReopenRequested, object: nil)
        return false
    }
}
