public enum AppModule: String, CaseIterable, Hashable, Sendable {
    case overview
    case activity
    case accounts
    case projects
    case toolsAndSkills
    case projectServices

    public var title: String {
        switch self {
        case .overview: "概览"
        case .activity: "操作日志"
        case .accounts: "账号管理"
        case .projects: "项目与任务"
        case .toolsAndSkills: "工具与自动化"
        case .projectServices: "项目服务"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .activity: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .accounts: "person.2"
        case .projects: "folder.badge.gearshape"
        case .toolsAndSkills: "wrench.and.screwdriver"
        case .projectServices: "server.rack"
        }
    }
}

public enum WorkbenchLayout {
    public static let minimumWidth = 900.0
    public static let minimumHeight = 640.0
    public static let minimumContentHeight = 588.0
    public static let defaultWidth = 1_160.0
    public static let defaultHeight = 780.0
    public static let sidebarMinimum = 188.0
    public static let sidebarIdeal = 216.0
    public static let sidebarMaximum = 248.0
    public static let spacingUnit = 8.0
}

public enum WorkbenchInterfaceContract {
    public static let pageTitleSize = 20.0
    public static let sectionTitleSize = 13.0
    public static let bodySize = 13.0
    public static let captionSize = 12.0
    public static let microSize = 11.0
}

public enum WorkbenchLaunchMode: Equatable, Sendable {
    case mainWindow
    case menuBarOnly
}

public enum WorkbenchLaunchPolicy {
    public static let loginItemArgument = "--login-item"

    public static func mode(arguments: [String]) -> WorkbenchLaunchMode {
        arguments.contains(loginItemArgument) ? .menuBarOnly : .mainWindow
    }
}

public enum WorkbenchBundleContract {
    public static let mainIdentifier = "com.hd2yao.codex-workbench"
    public static let loginHelperIdentifier = "com.hd2yao.codex-workbench.login-helper"
    public static let loginHelperAppName = "Codex Workbench Login Helper"
}
