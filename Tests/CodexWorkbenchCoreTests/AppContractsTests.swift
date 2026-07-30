import CodexWorkbenchCore

func runAppContractsTests(_ runner: inout TestRunner) {
    runner.expect(
        AppModule.allCases == [.overview, .activity, .accounts, .projects, .toolsAndSkills, .projectServices],
        "Primary modules should keep operations first and analysis modules after accounts"
    )
    runner.expect(AppModule.overview.title == "概览", "Overview title should be localized")
    runner.expect(AppModule.activity.title == "操作日志", "Activity title should be localized")
    runner.expect(AppModule.accounts.title == "账号管理", "Accounts title should be localized")
    runner.expect(AppModule.projects.title == "项目与任务", "Projects title should include real tasks")
    runner.expect(
        AppModule.toolsAndSkills.title == "工具与自动化",
        "Tools title should include hooks and automations"
    )
    runner.expect(
        AppModule.allCases.allSatisfy { !$0.systemImage.isEmpty },
        "Every module should have an SF Symbol"
    )
    runner.expect(WorkbenchLayout.minimumWidth == 900, "Minimum window width should match Design Lock")
    runner.expect(WorkbenchLayout.minimumHeight == 640, "Minimum window height should match Design Lock")
    runner.expect(
        WorkbenchLayout.minimumContentHeight == 588,
        "Content minimum should account for the standard 52pt titlebar"
    )
    runner.expect(WorkbenchLayout.defaultWidth == 1_160, "Default width should match Design Lock")
    runner.expect(WorkbenchLayout.defaultHeight == 780, "Default height should match Design Lock")
    runner.expect(
        WorkbenchLayout.sidebarMinimum == 188 && WorkbenchLayout.sidebarMaximum == 248,
        "Sidebar bounds should match Design Lock"
    )
    runner.expect(WorkbenchLayout.spacingUnit == 8, "Spacing should use an 8pt base unit")
}
