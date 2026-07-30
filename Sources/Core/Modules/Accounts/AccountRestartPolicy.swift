import Foundation

public enum AccountRestartConfirmationReason: Equatable, Sendable {
    case runningTask
    case waitingTask
    case unknownState
}

public enum AccountRestartDecision: Equatable, Sendable {
    case restartNow
    case confirm(AccountRestartConfirmationReason)
}

public enum AccountRestartPolicy {
    public static func decision(runtimeState: String?) -> AccountRestartDecision {
        switch runtimeState {
        case "idle": .restartNow
        case "running": .confirm(.runningTask)
        case "waiting": .confirm(.waitingTask)
        default: .confirm(.unknownState)
        }
    }
}

public enum AccountRestartVerification: Equatable, Sendable {
    case verified(profile: String)
    case mismatch(expected: String?, actual: String?)
}

public enum AccountRestartVerifier {
    public static func verify(
        payload: AccountDashboardPayload,
        expectedMode: AccountMode,
        expectedProfile: String?
    ) -> AccountRestartVerification {
        guard payload.accountMode == expectedMode else {
            return .mismatch(expected: expectedProfile, actual: payload.activeProfile)
        }

        if expectedMode == .localDefault {
            guard
                expectedProfile == "local-default",
                payload.activeProfile == "local-default",
                payload.desktopStatus?.running == true
            else {
                return .mismatch(expected: expectedProfile, actual: payload.activeProfile)
            }
            return .verified(profile: "local-default")
        }

        guard let expectedProfile else {
            return .mismatch(expected: nil, actual: payload.activeProfile)
        }
        switch AccountSwitchVerifier.verify(
            payload: payload,
            expectedProfile: expectedProfile
        ) {
        case .expectedDesktopDefault:
            return .verified(profile: expectedProfile)
        case .mismatch(_, let actual), .unmanaged(let actual):
            return .mismatch(expected: expectedProfile, actual: actual)
        }
    }
}
