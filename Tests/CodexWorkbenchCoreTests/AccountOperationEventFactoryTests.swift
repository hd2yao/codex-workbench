import CodexWorkbenchCore
import Foundation

func runAccountOperationEventFactoryTests(_ runner: inout TestRunner) {
    let at = Date(timeIntervalSince1970: 2_000)
    let success = AccountOperationEventFactory.switchSucceeded(
        from: "hd-master",
        to: "hd-sarah-blackwell",
        at: at
    )
    runner.expect(success.action == "account_switched", "Verified switch should use the success action")
    runner.expect(success.status == .success, "Verified switch should be a success")
    runner.expect(
        success.certainty == .inferred
            && success.summary.contains("预期桌面默认账号")
            && !success.summary.contains("实际登录状态"),
        "A switch must not claim independent attestation of the launched process login"
    )
    runner.expect(success.account?.profile == "hd-sarah-blackwell", "Switch event should retain the target account")
    runner.expect(success.actor.id == "codex-workbench", "Switch event should be owned by the workbench")
    runner.expect(
        success.before == .object(["desktop_profile": .string("hd-master")])
            && success.after == .object(["desktop_profile": .string("hd-sarah-blackwell")]),
        "Verified switches should retain before and after accounts"
    )
    runner.expect(
        success.sourceChain.map(\.id) == ["codex-workbench", "codex-profile-switcher"],
        "Switch evidence should identify the workbench and the mature account engine"
    )

    let failure = AccountOperationEventFactory.switchFailed(
        expected: "hd-sarah-blackwell",
        actual: "hd-master",
        reason: "verification_mismatch",
        at: at
    )
    runner.expect(failure.action == "account_switch_failed", "Failed verification should use a failure action")
    runner.expect(failure.status == .failure, "Failed verification should be a failure")
    runner.expect(
        failure.summary.contains("目标 hd-sarah-blackwell，实际 hd-master"),
        "Failure should explain the target and actual account"
    )
    runner.expect(
        failure.after == .object(["actual_profile": .string("hd-master")]),
        "Failure evidence should retain the actual account without credentials"
    )

    let restart = AccountOperationEventFactory.restartSucceeded(
        profile: "hd-master",
        clientDisplayName: "ChatGPT",
        at: at
    )
    runner.expect(restart.action == "account_restarted", "Verified restart should use its own action")
    runner.expect(restart.status == .success, "Verified restart should be a success")
    runner.expect(restart.importance == .important, "Restart should be visible without being critical")
    runner.expect(
        restart.certainty == .inferred
            && !restart.summary.contains("验证当前账号"),
        "A restart must not overclaim process-level account verification"
    )
    runner.expect(
        restart.title == "已重启 ChatGPT"
            && restart.summary.contains("安全重启 ChatGPT"),
        "Restart events should name the exact desktop client"
    )

    let cancelled = AccountOperationEventFactory.restartCancelled(profile: "hd-master", at: at)
    runner.expect(cancelled.action == "restart_cancelled", "Cancelled restart should be explicit")
    runner.expect(cancelled.status == .skipped, "Cancelled restart should not look like a failure")
    runner.expect(cancelled.importance == .routine, "Cancellation should remain a routine event")

    let restartFailure = AccountOperationEventFactory.restartFailed(
        profile: "hd-master",
        reason: "/Users/private/.codex/auth.json token=secret",
        at: at
    )
    let safeText = restartFailure.title + restartFailure.summary
        + restartFailure.evidence.map(\.label).joined(separator: " ")
    runner.expect(!safeText.contains("auth.json"), "Restart logs must not expose auth paths")
    runner.expect(!safeText.lowercased().contains("token"), "Restart logs must not expose token details")

    let identityFailure = AccountOperationEventFactory.restartFailed(
        profile: "hd-master",
        reason: "desktop_identity_mismatch",
        clientDisplayName: "Codex",
        at: at
    )
    runner.expect(
        identityFailure.title == "Codex 重启未完成"
            && identityFailure.evidence.first?.label == "桌面客户端进程身份不匹配",
        "Compatibility-client identity failures should remain dynamic and redacted"
    )
}
