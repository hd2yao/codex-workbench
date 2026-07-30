import CodexWorkbenchCore

func runWorkbenchLaunchPolicyTests(_ runner: inout TestRunner) {
    runner.expect(
        WorkbenchLaunchPolicy.mode(arguments: ["CodexWorkbenchApp"]) == .mainWindow,
        "A normal user launch should present the main workbench window"
    )
    runner.expect(
        WorkbenchLaunchPolicy.mode(arguments: ["CodexWorkbenchApp", "--login-item"]) == .menuBarOnly,
        "The login helper launch should stay in the menu bar"
    )
    runner.expect(
        WorkbenchLaunchPolicy.mode(arguments: ["CodexWorkbenchApp", "--unrelated"]) == .mainWindow,
        "Unknown arguments must not accidentally suppress the main window"
    )
    runner.expect(
        WorkbenchBundleContract.mainIdentifier == "com.hd2yao.codex-workbench",
        "The main bundle identifier should stay stable"
    )
    runner.expect(
        WorkbenchBundleContract.loginHelperIdentifier == "com.hd2yao.codex-workbench.login-helper",
        "The login helper identifier should stay stable for SMAppService"
    )
}
