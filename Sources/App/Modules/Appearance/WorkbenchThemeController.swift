import AppKit
import CodexWorkbenchCore

@MainActor
enum WorkbenchThemeController {
    static var persistedPreference: WorkbenchAppearancePreference {
        WorkbenchAppearancePreference.persisted(
            UserDefaults.standard.string(
                forKey: WorkbenchAppearancePreference.defaultsKey
            )
        )
    }

    static func applyPersistedPreference() {
        apply(persistedPreference, persist: false)
    }

    static func apply(
        _ preference: WorkbenchAppearancePreference,
        persist: Bool = true
    ) {
        if persist {
            UserDefaults.standard.set(
                preference.rawValue,
                forKey: WorkbenchAppearancePreference.defaultsKey
            )
        }
        NSApp.appearance = preference.appKitName
            .map { NSAppearance(named: NSAppearance.Name(rawValue: $0)) }
            ?? nil
    }
}
