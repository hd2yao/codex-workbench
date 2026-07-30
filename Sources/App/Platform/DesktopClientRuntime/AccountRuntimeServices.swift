import AppKit
import CodexWorkbenchCore
import Foundation

struct CodexAppProbeResult {
    let installations: [DiagnosticAppInstallation]
    let selectedAppURL: URL?
}

protocol CodexAppProbing {
    func probe() -> CodexAppProbeResult
}

struct LiveCodexAppProbe: CodexAppProbing {
    func probe() -> CodexAppProbeResult {
        let workspace = NSWorkspace.shared
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexIntegration.bundleIdentifier
        )
        let selected = workspace.urlForApplication(
            withBundleIdentifier: CodexIntegration.bundleIdentifier
        )
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        var candidates: [URL] = []
        if let selected { candidates.append(selected) }
        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            homeApplications.appendingPathComponent("ChatGPT.app", isDirectory: true),
            homeApplications.appendingPathComponent("Codex.app", isDirectory: true),
        ]

        let runningInstallations = running.compactMap {
            application -> DiagnosticAppInstallation? in
            guard let url = application.bundleURL?.standardizedFileURL else {
                return nil
            }
            guard
                let bundle = Bundle(url: url),
                bundle.bundleIdentifier == CodexIntegration.bundleIdentifier
            else { return nil }
            let version = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
            return DiagnosticAppInstallation(
                url: url,
                bundleIdentifier: bundle.bundleIdentifier ?? "",
                version: version,
                isRunning: true,
                processIdentifier: application.processIdentifier
            )
        }
        let runningPaths = Set(runningInstallations.map {
            $0.url.standardizedFileURL.resolvingSymlinksInPath().path
        })
        var seen = runningPaths
        let installed = candidates.compactMap { candidate -> DiagnosticAppInstallation? in
            let url = candidate.standardizedFileURL
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard seen.insert(resolvedPath).inserted else { return nil }
            guard
                FileManager.default.fileExists(atPath: url.path),
                let bundle = Bundle(url: url),
                bundle.bundleIdentifier == CodexIntegration.bundleIdentifier
            else { return nil }
            let version = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
            return DiagnosticAppInstallation(
                url: url,
                bundleIdentifier: bundle.bundleIdentifier ?? "",
                version: version,
                isRunning: false,
                processIdentifier: nil
            )
        }
        let installations = runningInstallations + installed
        return CodexAppProbeResult(installations: installations, selectedAppURL: selected)
    }
}

enum AccountRuntimeServices {
    static func legacyProfileSwitcherIsRunning() -> Bool {
        AccountRuntimePolicy.legacyProfileSwitcherIsRunning(
            bundleIdentifiers: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
    }

    static func diagnosticSnapshot(
        payload: AccountDashboardPayload?,
        recentFailureStage: String? = nil,
        probe: any CodexAppProbing = LiveCodexAppProbe(),
        backendAvailable: Bool? = nil
    ) -> WorkbenchDiagnosticSnapshot {
        let probeResult = probe.probe()
        return WorkbenchDiagnosticsBuilder.build(
            WorkbenchDiagnosticInput(
                installedApps: probeResult.installations,
                selectedAppURL: probeResult.selectedAppURL,
                backendAvailable: backendAvailable ?? bundledAccountBackendIsExecutable(),
                accountMode: payload?.accountMode ?? .unavailable,
                accountStorageMode: payload?.accountStorage.mode,
                managedProfileCount: payload?.accountMode == .managedProfiles
                    ? payload?.profiles.filter { $0.name != "local-default" }.count ?? 0
                    : 0,
                defaultHomeAvailable: defaultAccountHomeAvailable(),
                recentFailureStage: recentFailureStage
            )
        )
    }

    static func bundledAccountBackendIsExecutable(
        resourceURL: URL? = Bundle.main.resourceURL
    ) -> Bool {
        guard let resourceURL else { return false }
        let executableURL = resourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CodexAccountBackend", isDirectory: true)
            .appendingPathComponent("CodexAccountBackend")
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    static func defaultAccountHomeAvailable(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        let authURL = homeURL.appendingPathComponent(".codex/auth.json")
        return fileManager.isReadableFile(atPath: authURL.path)
    }
}
