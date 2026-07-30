import CodexWorkbenchCore

func runCodexIntegrationTests(_ runner: inout TestRunner) {
    let threadID = "6a5620e6-c00c-83ec-869b-19d5f8de738b"

    runner.expect(
        CodexIntegration.bundleIdentifier == "com.openai.codex",
        "Codex bundle identifier should match the installed desktop app"
    )
    runner.expect(
        CodexIntegration.threadURL(for: threadID)?.absoluteString
            == "codex://threads/6a5620e6-c00c-83ec-869b-19d5f8de738b",
        "Valid task UUID should form a Codex thread deep link"
    )
    runner.expect(
        CodexIntegration.threadURL(for: "not-a-thread") == nil,
        "Invalid task identifiers must not form deep links"
    )
    runner.expect(
        CodexIntegration.threadURL(for: "6a5620e6-c00c-83ec-869b-19d5f8de738b/extra") == nil,
        "Task links must not accept path injection"
    )
}
