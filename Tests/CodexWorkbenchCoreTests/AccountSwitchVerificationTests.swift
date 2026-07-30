import CodexWorkbenchCore
import Foundation

func runAccountSwitchVerificationTests(_ runner: inout TestRunner) {
    let expected = AccountSwitchVerifier.verify(
        payload: switchPayload(active: "hd-master", desktop: "hd-master", managed: true),
        expectedProfile: "hd-master"
    )
    runner.expect(
        expected == .expectedDesktopDefault(profile: "hd-master"),
        "Matching internal labels only establish the expected desktop default"
    )

    let activeMismatch = AccountSwitchVerifier.verify(
        payload: switchPayload(active: "hd-sarah-blackwell", desktop: "hd-sarah-blackwell", managed: true),
        expectedProfile: "hd-master"
    )
    runner.expect(
        activeMismatch == .mismatch(expected: "hd-master", actual: "hd-sarah-blackwell"),
        "A different active profile must not be reported as success"
    )

    let desktopMismatch = AccountSwitchVerifier.verify(
        payload: switchPayload(active: "hd-master", desktop: "hd-sarah-blackwell", managed: true),
        expectedProfile: "hd-master"
    )
    runner.expect(
        desktopMismatch == .mismatch(expected: "hd-master", actual: "hd-sarah-blackwell"),
        "The managed desktop profile must agree with the active profile"
    )

    let unmanaged = AccountSwitchVerifier.verify(
        payload: switchPayload(active: "hd-master", desktop: "hd-master", managed: false),
        expectedProfile: "hd-master"
    )
    runner.expect(unmanaged == .unmanaged(profile: "hd-master"), "An unmanaged bridge must not verify")

    let unknown = AccountSwitchVerifier.verify(
        payload: switchPayload(active: nil, desktop: nil, managed: true),
        expectedProfile: "hd-master"
    )
    runner.expect(
        unknown == .mismatch(expected: "hd-master", actual: nil),
        "Missing account evidence must stay unverified"
    )
}

private func switchPayload(active: String?, desktop: String?, managed: Bool) -> AccountDashboardPayload {
    AccountDashboardPayload(
        generatedAt: Date(timeIntervalSince1970: 1_000),
        activeProfile: active,
        desktopStatus: AccountDesktopStatus(
            running: true,
            managed: managed,
            state: managed ? "managed_default_home" : "manual_launch",
            message: nil,
            activeProfile: desktop
        ),
        profileRoles: nil,
        profiles: []
    )
}
