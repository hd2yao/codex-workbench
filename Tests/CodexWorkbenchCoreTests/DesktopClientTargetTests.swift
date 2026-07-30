import CodexWorkbenchCore
import Foundation

func runDesktopClientTargetTests(_ runner: inout TestRunner) {
    let chatGPTURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    let codexURL = URL(fileURLWithPath: "/Applications/Codex.app")

    let runningChatGPT = DesktopClientTargetSelector.select(
        installations: [
            DiagnosticAppInstallation(
                url: chatGPTURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: true,
                processIdentifier: 42
            ),
            DiagnosticAppInstallation(
                url: codexURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: false
            ),
        ],
        selectedURL: codexURL
    )
    runner.expect(
        runningChatGPT.target?.appURL == chatGPTURL,
        "The one running desktop bundle path must win"
    )
    runner.expect(
        runningChatGPT.target?.processIdentifier == 42,
        "The running desktop PID must be preserved"
    )
    runner.expect(
        runningChatGPT.target?.restartLabel == "重启 ChatGPT",
        "Restart copy must use the actual desktop client name"
    )
    runner.expect(
        runningChatGPT.target?.compactIdentityDetail
            == "ChatGPT · PID 42 · 当前运行实例",
        "Compact surfaces must identify the actual client without truncating a full path"
    )
    runner.expect(
        runningChatGPT.target?.selectionReason == .runningInstance,
        "The selection reason must remain inspectable"
    )

    let runningCodex = DesktopClientTargetSelector.select(
        installations: [
            DiagnosticAppInstallation(
                url: chatGPTURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: false
            ),
            DiagnosticAppInstallation(
                url: codexURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: true,
                processIdentifier: 84
            ),
        ],
        selectedURL: chatGPTURL
    )
    runner.expect(
        runningCodex.target?.displayName == "Codex",
        "A running Codex compatibility installation must remain targetable"
    )
    runner.expect(
        runningCodex.target?.openLabel == "切到 Codex",
        "Open copy must reflect the selected running compatibility client"
    )

    let chatGPTFirst = DesktopClientTargetSelector.select(
        installations: [
            DiagnosticAppInstallation(
                url: codexURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: false
            ),
            DiagnosticAppInstallation(
                url: chatGPTURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: false
            ),
        ],
        selectedURL: codexURL
    )
    runner.expect(
        chatGPTFirst.target?.appURL == chatGPTURL,
        "When nothing runs, the maintained ChatGPT bundle must be preferred"
    )
    runner.expect(
        chatGPTFirst.target?.selectionReason == .chatGPTPreferred,
        "ChatGPT-first fallback must be explicit"
    )

    let ambiguous = DesktopClientTargetSelector.select(
        installations: [
            DiagnosticAppInstallation(
                url: chatGPTURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: true,
                processIdentifier: 42
            ),
            DiagnosticAppInstallation(
                url: codexURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: true,
                processIdentifier: 84
            ),
        ],
        selectedURL: chatGPTURL
    )
    runner.expect(
        ambiguous.status == .ambiguous,
        "Two running main desktop clients must fail closed"
    )
    runner.expect(
        ambiguous.target == nil,
        "An ambiguous result must not expose an actionable target"
    )

    let samePathAmbiguous = DesktopClientTargetSelector.select(
        installations: [
            DiagnosticAppInstallation(
                url: chatGPTURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: true,
                processIdentifier: 42
            ),
            DiagnosticAppInstallation(
                url: chatGPTURL,
                bundleIdentifier: CodexIntegration.bundleIdentifier,
                version: "1",
                isRunning: true,
                processIdentifier: 43
            ),
        ],
        selectedURL: chatGPTURL
    )
    runner.expect(
        samePathAmbiguous.status == .ambiguous,
        "Two main-process PIDs from the same app path must fail closed"
    )

    let unavailable = DesktopClientTargetSelector.select(
        installations: [],
        selectedURL: nil
    )
    runner.expect(unavailable.status == .unavailable, "Missing desktop clients must stay explicit")
    runner.expect(
        unavailable.unavailableReason == "未找到可用的 ChatGPT/Codex 桌面客户端",
        "Unavailable presentation must include a stable reason"
    )

    let verified = DesktopClientRestartVerifier.verify(
        previous: runningChatGPT.target,
        current: DesktopClientTarget(
            appURL: chatGPTURL,
            processIdentifier: 99,
            isRunning: true,
            selectionReason: .runningInstance
        )
    )
    runner.expect(verified, "The same path with a new PID must verify")
    runner.expect(
        !DesktopClientRestartVerifier.verify(
            previous: runningChatGPT.target,
            current: DesktopClientTarget(
                appURL: codexURL,
                processIdentifier: 99,
                isRunning: true,
                selectionReason: .runningInstance
            )
        ),
        "A new PID from a different app path must not verify"
    )
    runner.expect(
        !DesktopClientRestartVerifier.verify(
            previous: runningChatGPT.target,
            current: runningChatGPT.target
        ),
        "The old PID must not verify as a restart"
    )
}
