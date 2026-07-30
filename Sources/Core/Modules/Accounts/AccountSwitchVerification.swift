import Foundation

public enum AccountSwitchVerification: Equatable, Sendable {
    case expectedDesktopDefault(profile: String)
    case mismatch(expected: String, actual: String?)
    case unmanaged(profile: String?)
}

public enum AccountSwitchVerifier {
    public static func verify(
        payload: AccountDashboardPayload,
        expectedProfile: String
    ) -> AccountSwitchVerification {
        guard payload.activeProfile == expectedProfile else {
            return .mismatch(expected: expectedProfile, actual: payload.activeProfile)
        }
        guard payload.desktopStatus?.activeProfile == expectedProfile else {
            return .mismatch(
                expected: expectedProfile,
                actual: payload.desktopStatus?.activeProfile
            )
        }
        guard payload.desktopStatus?.managed == true else {
            return .unmanaged(profile: payload.activeProfile)
        }
        return .expectedDesktopDefault(profile: expectedProfile)
    }
}
