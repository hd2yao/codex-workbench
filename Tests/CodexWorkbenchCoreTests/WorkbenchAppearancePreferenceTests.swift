import CodexWorkbenchCore

func runWorkbenchAppearancePreferenceTests(_ runner: inout TestRunner) {
    runner.expect(
        WorkbenchAppearancePreference(rawValue: "system") == .system,
        "System appearance should decode"
    )
    runner.expect(
        WorkbenchAppearancePreference.persisted("unknown") == .system,
        "Unknown persisted appearances should follow the system"
    )
    runner.expect(
        WorkbenchAppearancePreference.allCases.map(\.title)
            == ["跟随系统", "浅色", "深色"],
        "Appearance titles should be localized and stable"
    )
    runner.expect(
        WorkbenchAppearancePreference.allCases.map(\.systemImage)
            == ["circle.lefthalf.filled", "sun.max.fill", "moon.fill"],
        "Appearance options should use discoverable SF Symbols"
    )
    runner.expect(
        WorkbenchAppearancePreference.system.appKitName == nil,
        "System appearance should clear the AppKit override"
    )
    runner.expect(
        WorkbenchAppearancePreference.light.appKitName == "NSAppearanceNameAqua",
        "Light appearance should map to Aqua"
    )
    runner.expect(
        WorkbenchAppearancePreference.dark.appKitName == "NSAppearanceNameDarkAqua",
        "Dark appearance should map to Dark Aqua"
    )
}
