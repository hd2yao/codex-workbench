import CodexWorkbenchCore
import Foundation

func runAccountRestartPolicyTests(_ runner: inout TestRunner) {
    runner.expect(
        AccountRestartPolicy.decision(runtimeState: "idle") == .restartNow,
        "An idle Codex runtime should restart immediately"
    )
    runner.expect(
        AccountRestartPolicy.decision(runtimeState: "running") == .confirm(.runningTask),
        "A running task must require confirmation"
    )
    runner.expect(
        AccountRestartPolicy.decision(runtimeState: "waiting") == .confirm(.waitingTask),
        "A waiting task must require confirmation"
    )
    runner.expect(
        AccountRestartPolicy.decision(runtimeState: "unknown") == .confirm(.unknownState),
        "An unknown runtime state must fail safe"
    )
    runner.expect(
        AccountRestartPolicy.decision(runtimeState: nil) == .confirm(.unknownState),
        "Missing runtime evidence must fail safe"
    )

    let managed = AccountRestartVerifier.verify(
        payload: restartPayload(
            mode: .managedProfiles,
            active: "hd-master",
            desktop: "hd-master",
            managed: true
        ),
        expectedMode: .managedProfiles,
        expectedProfile: "hd-master"
    )
    runner.expect(
        managed == .verified(profile: "hd-master"),
        "A managed restart must preserve and verify the current profile"
    )

    let local = AccountRestartVerifier.verify(
        payload: restartPayload(
            mode: .localDefault,
            active: "local-default",
            desktop: "local-default",
            managed: false
        ),
        expectedMode: .localDefault,
        expectedProfile: "local-default"
    )
    runner.expect(
        local == .verified(profile: "local-default"),
        "A local restart must verify the read-only default account without a bridge"
    )

    let changed = AccountRestartVerifier.verify(
        payload: restartPayload(
            mode: .managedProfiles,
            active: "hd-other",
            desktop: "hd-other",
            managed: true
        ),
        expectedMode: .managedProfiles,
        expectedProfile: "hd-master"
    )
    runner.expect(
        changed == .mismatch(expected: "hd-master", actual: "hd-other"),
        "A restart must not succeed after the active account changes"
    )
}

private func restartPayload(
    mode: AccountMode,
    active: String?,
    desktop: String?,
    managed: Bool
) -> AccountDashboardPayload {
    AccountDashboardPayload(
        generatedAt: Date(timeIntervalSince1970: 1_000),
        activeProfile: active,
        accountMode: mode,
        desktopStatus: AccountDesktopStatus(
            running: true,
            managed: managed,
            state: managed ? "managed_default_home" : "local_default",
            message: nil,
            activeProfile: desktop
        ),
        profileRoles: nil,
        profiles: []
    )
}
