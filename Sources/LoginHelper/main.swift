import AppKit
import CodexWorkbenchCore
import Foundation

let running = NSRunningApplication.runningApplications(
    withBundleIdentifier: WorkbenchBundleContract.mainIdentifier
)
guard running.isEmpty else {
    exit(EXIT_SUCCESS)
}

var mainAppURL = Bundle.main.bundleURL
for _ in 0..<4 {
    mainAppURL.deleteLastPathComponent()
}
guard
    let mainBundle = Bundle(url: mainAppURL),
    mainBundle.bundleIdentifier == WorkbenchBundleContract.mainIdentifier
else {
    exit(EXIT_SUCCESS)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.arguments = [WorkbenchLaunchPolicy.loginItemArgument]
NSWorkspace.shared.openApplication(at: mainAppURL, configuration: configuration) { _, _ in
    exit(EXIT_SUCCESS)
}
RunLoop.main.run()
