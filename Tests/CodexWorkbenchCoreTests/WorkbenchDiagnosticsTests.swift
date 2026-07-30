import CodexWorkbenchCore
import Foundation

func runWorkbenchDiagnosticsTests(_ runner: inout TestRunner) {
    let duplicate = WorkbenchDiagnosticsBuilder.build(
        WorkbenchDiagnosticInput(
            installedApps: [
                DiagnosticAppInstallation(
                    url: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                    bundleIdentifier: CodexIntegration.bundleIdentifier,
                    version: "1.2.3",
                    isRunning: true
                ),
                DiagnosticAppInstallation(
                    url: URL(fileURLWithPath: "/Applications/Codex.app"),
                    bundleIdentifier: CodexIntegration.bundleIdentifier,
                    version: "1.2.2",
                    isRunning: false
                ),
            ],
            selectedAppURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            backendAvailable: true,
            accountMode: .managedProfiles,
            managedProfileCount: 2,
            defaultHomeAvailable: true,
            recentFailureStage: "verification_mismatch"
        )
    )
    runner.expect(
        duplicate.findings.contains { $0.id == "duplicate-codex-apps" && $0.level == .warning },
        "Duplicate Codex apps must be called out as a warning"
    )
    runner.expect(
        duplicate.findings.contains { $0.id == "account-managed-profiles" },
        "Managed profile mode should be explicit"
    )
    runner.expect(
        duplicate.findings.contains { $0.id == "default-home-readable" },
        "Diagnostics should report default Codex home availability independently of account mode"
    )
    runner.expect(
        duplicate.appSummaries.allSatisfy {
            $0.contains("bundle \(CodexIntegration.bundleIdentifier)")
        },
        "Every app summary should report the parsed bundle identifier"
    )
    runner.expect(
        duplicate.findings.contains { $0.id == "recent-account-failure" },
        "A recent safe failure stage should remain actionable"
    )

    let identityFailure = WorkbenchDiagnosticsBuilder.build(
        WorkbenchDiagnosticInput(
            installedApps: [
                DiagnosticAppInstallation(
                    url: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                    bundleIdentifier: CodexIntegration.bundleIdentifier,
                    version: "1.2.3",
                    isRunning: true,
                    processIdentifier: 42
                )
            ],
            selectedAppURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            backendAvailable: true,
            accountMode: .managedProfiles,
            accountStorageMode: .unifiedVault,
            managedProfileCount: 2,
            defaultHomeAvailable: true,
            recentFailureStage: "desktop_identity_mismatch"
        )
    )
    runner.expect(
        identityFailure.findings.contains {
            $0.id == "recent-account-failure" && $0.detail.contains("路径或进程")
        },
        "Desktop identity mismatches should remain visible in diagnostics"
    )
    runner.expect(
        identityFailure.clientIdentityLines.contains {
            $0.contains("/Applications/ChatGPT.app")
                && $0.contains("PID 42")
                && $0.contains("当前运行实例")
        },
        "Diagnostics should display exact path, PID, and client selection reason"
    )
    runner.expect(
        identityFailure.findings.contains { $0.id == "account-unified-vault" }
            && identityFailure.findings.contains {
                $0.id == "official-app-server-verification"
            },
        "Diagnostics should distinguish Codex Home storage from official App Server verification"
    )
    runner.expect(
        duplicate.revealTargets.count == 2,
        "Every discovered Codex app should be available as a vetted Finder target"
    )
    runner.expect(
        !duplicate.copyableSummary.contains("auth.json"),
        "Diagnostic summary must not expose auth file names"
    )
    runner.expect(
        !duplicate.copyableSummary.lowercased().contains("token"),
        "Diagnostic summary must remain redacted"
    )
    runner.expect(
        !duplicate.copyableSummary.contains("/Applications/"),
        "Diagnostic summary must not expose full application paths"
    )

    let single = WorkbenchDiagnosticsBuilder.build(
        WorkbenchDiagnosticInput(
            installedApps: [
                DiagnosticAppInstallation(
                    url: URL(fileURLWithPath: "/Applications/Codex.app"),
                    bundleIdentifier: CodexIntegration.bundleIdentifier,
                    version: "1.2.3",
                    isRunning: false
                )
            ],
            selectedAppURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            backendAvailable: true,
            accountMode: .localDefault,
            managedProfileCount: 0,
            defaultHomeAvailable: true
        )
    )
    runner.expect(
        single.findings.contains { $0.id == "codex-app-ready" && $0.level == .info },
        "A single installation should be reported as ready"
    )
    runner.expect(
        single.findings.contains { $0.id == "account-local-default" },
        "Local default account mode should be explicit"
    )

    let missing = WorkbenchDiagnosticsBuilder.build(
        WorkbenchDiagnosticInput(
            installedApps: [],
            selectedAppURL: nil,
            backendAvailable: false,
            accountMode: .unavailable,
            managedProfileCount: 0,
            defaultHomeAvailable: false
        )
    )
    runner.expect(
        missing.findings.contains { $0.id == "codex-app-missing" && $0.level == .error },
        "A missing Codex app should be actionable"
    )
    runner.expect(
        missing.findings.contains { $0.id == "account-backend-missing" && $0.level == .error },
        "A missing bundled backend should be actionable"
    )
    runner.expect(
        missing.findings.contains { $0.id == "account-unavailable" && $0.level == .error },
        "An unavailable account source should remain explicit"
    )
    runner.expect(
        missing.findings.contains { $0.id == "default-home-unavailable" && $0.level == .warning },
        "Diagnostics should distinguish a missing default Codex home"
    )

    let ambiguous = WorkbenchDiagnosticsBuilder.build(
        WorkbenchDiagnosticInput(
            installedApps: [
                DiagnosticAppInstallation(
                    url: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                    bundleIdentifier: CodexIntegration.bundleIdentifier,
                    version: "1",
                    isRunning: true,
                    processIdentifier: 42
                ),
                DiagnosticAppInstallation(
                    url: URL(fileURLWithPath: "/Applications/Codex.app"),
                    bundleIdentifier: CodexIntegration.bundleIdentifier,
                    version: "1",
                    isRunning: true,
                    processIdentifier: 84
                ),
            ],
            selectedAppURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            backendAvailable: true,
            accountMode: .managedProfiles,
            managedProfileCount: 2,
            defaultHomeAvailable: true
        )
    )
    runner.expect(
        ambiguous.findings.contains {
            $0.id == "desktop-client-ambiguous" && $0.level == .error
        },
        "Two running main clients should disable actions and open an actionable diagnostic"
    )
}
