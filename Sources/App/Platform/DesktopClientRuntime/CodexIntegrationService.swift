import AppKit
import CodexWorkbenchCore

enum CodexIntegrationService {
    static func openCodex() {
        let result = LiveCodexAppProbe().probe()
        let selection = DesktopClientTargetSelector.select(
            installations: result.installations,
            selectedURL: result.selectedAppURL
        )
        openDesktopClient(selection.target)
    }

    static func openDesktopClient(_ target: DesktopClientTarget?) {
        guard let target, target.isSafeCommandTarget else { return }
        if
            let processIdentifier = target.processIdentifier,
            let running = NSRunningApplication(processIdentifier: processIdentifier),
            running.bundleURL?
                .standardizedFileURL
                .resolvingSymlinksInPath() == target.appURL
        {
            running.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: target.appURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    static func openThread(_ threadID: String) {
        guard let url = CodexIntegration.threadURL(for: threadID) else { return }
        NSWorkspace.shared.open(url)
    }

    static func revealDiagnosticTarget(_ target: DiagnosticRevealTarget) {
        NSWorkspace.shared.activateFileViewerSelecting([target.url])
    }

    static func copyDiagnosticSummary(_ snapshot: WorkbenchDiagnosticSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.copyableSummary, forType: .string)
    }
}
