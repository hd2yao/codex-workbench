import CodexWorkbenchCore

func runAccountRuntimePolicyTests(_ runner: inout TestRunner) {
    let legacyBundleID = AccountRuntimePolicy.legacyProfileSwitcherBundleIdentifier

    runner.expect(
        AccountRuntimePolicy.legacyProfileSwitcherIsRunning(
            bundleIdentifiers: ["com.openai.codex", legacyBundleID]
        ),
        "The legacy Profile Switcher process should be detected by its exact bundle identifier"
    )
    runner.expect(
        !AccountRuntimePolicy.legacyProfileSwitcherIsRunning(
            bundleIdentifiers: ["com.openai.codex", "com.hd2yao.codex-workbench"]
        ),
        "Unrelated Codex apps must not trigger the cold-backup conflict"
    )
    runner.expect(
        AccountRuntimePolicy.automationAvailability(legacyProfileSwitcherRunning: true)
            == .pausedForLegacyProfileSwitcher,
        "Account automation must pause while the cold-backup app is running"
    )
    runner.expect(
        AccountRuntimePolicy.automationAvailability(legacyProfileSwitcherRunning: false)
            == .available,
        "Account automation should stay available when only the workbench is running"
    )
    runner.expect(
        AccountRuntimePolicy.automationAvailability(
            accountMode: .localDefault,
            legacyProfileSwitcherRunning: false
        ) == .readOnlyLocalAccount,
        "The read-only local account must never consume reset credits automatically"
    )
    runner.expect(
        AccountRuntimePolicy.automationAvailability(
            accountMode: .managedProfiles,
            storageMode: .legacyProfiles,
            legacyProfileSwitcherRunning: false
        ) == .available,
        "Managed profiles must preserve their existing automatic reset behavior"
    )
    runner.expect(
        AccountRuntimePolicy.automationAvailability(
            accountMode: .managedProfiles,
            storageMode: .unifiedVault,
            legacyProfileSwitcherRunning: false
        ) == .pausedForUnifiedVault,
        "Unified Vault snapshots must never become writable App Server homes"
    )
    runner.expect(
        !AccountRuntimePolicy.officialRateLimitObservationAllowed(
            storageMode: .unifiedVault
        ),
        "Unified Vault snapshots must not become persistent App Server homes"
    )
    runner.expect(
        AccountRuntimePolicy.officialRateLimitObservationAllowed(
            storageMode: .legacyProfiles
        ),
        "Legacy managed profiles should preserve official rate-limit notifications"
    )
}
