public enum AccountAutomationAvailability: Equatable, Sendable {
    case available
    case pausedForLegacyProfileSwitcher
    case pausedForUnifiedVault
    case readOnlyLocalAccount
}

public enum AccountRuntimePolicy {
    public static let legacyProfileSwitcherBundleIdentifier = "com.hd2yao.codex-profile-switcher"

    public static func legacyProfileSwitcherIsRunning(
        bundleIdentifiers: [String]
    ) -> Bool {
        bundleIdentifiers.contains(legacyProfileSwitcherBundleIdentifier)
    }

    public static func automationAvailability(
        accountMode: AccountMode = .managedProfiles,
        storageMode: AccountStorageMode? = nil,
        legacyProfileSwitcherRunning: Bool
    ) -> AccountAutomationAvailability {
        if accountMode == .localDefault {
            return .readOnlyLocalAccount
        }
        if storageMode == .unifiedVault {
            return .pausedForUnifiedVault
        }
        return legacyProfileSwitcherRunning ? .pausedForLegacyProfileSwitcher : .available
    }

    public static func officialRateLimitObservationAllowed(
        storageMode: AccountStorageMode?
    ) -> Bool {
        storageMode != .unifiedVault
    }
}
