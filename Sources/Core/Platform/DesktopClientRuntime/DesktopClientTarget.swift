import Foundation

public enum DesktopClientSelectionReason: String, Equatable, Sendable {
    case runningInstance = "running_instance"
    case chatGPTPreferred = "chatgpt_preferred"
    case systemSelection = "system_selection"
    case codexCompatibility = "codex_compatibility"
    case installedFallback = "installed_fallback"

    public var displayName: String {
        switch self {
        case .runningInstance: "当前运行实例"
        case .chatGPTPreferred: "优先选择 ChatGPT"
        case .systemSelection: "系统选择"
        case .codexCompatibility: "Codex 兼容回退"
        case .installedFallback: "已安装回退"
        }
    }
}

public enum DesktopClientSelectionStatus: String, Equatable, Sendable {
    case selected
    case ambiguous
    case unavailable
}

public struct DesktopClientTarget: Equatable, Sendable {
    public let appURL: URL
    public let processIdentifier: Int32?
    public let isRunning: Bool
    public let selectionReason: DesktopClientSelectionReason

    public init(
        appURL: URL,
        processIdentifier: Int32?,
        isRunning: Bool,
        selectionReason: DesktopClientSelectionReason
    ) {
        self.appURL = appURL.standardizedFileURL.resolvingSymlinksInPath()
        self.processIdentifier = processIdentifier
        self.isRunning = isRunning
        self.selectionReason = selectionReason
    }

    public var displayName: String {
        appURL.deletingPathExtension().lastPathComponent
    }

    public var openLabel: String {
        "\(isRunning ? "切到" : "打开") \(displayName)"
    }

    public var restartLabel: String {
        "重启 \(displayName)"
    }

    public var compactIdentityDetail: String {
        let process = processIdentifier.map { "PID \($0)" } ?? "未运行"
        return "\(displayName) · \(process) · \(selectionReason.displayName)"
    }

    public var isSafeCommandTarget: Bool {
        let path = appURL.path
        return appURL.isFileURL
            && path.hasPrefix("/")
            && appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && !path.contains("\0")
            && !path.contains("\n")
            && processIdentifier.map { $0 > 0 } ?? true
    }
}

public struct DesktopClientSelectionResult: Equatable, Sendable {
    public let status: DesktopClientSelectionStatus
    public let target: DesktopClientTarget?
    public let candidates: [DesktopClientTarget]
    public let unavailableReason: String?

    public init(
        status: DesktopClientSelectionStatus,
        target: DesktopClientTarget?,
        candidates: [DesktopClientTarget],
        unavailableReason: String?
    ) {
        self.status = status
        self.target = target
        self.candidates = candidates
        self.unavailableReason = unavailableReason
    }
}

public enum DesktopClientTargetSelector {
    public static func select(
        installations: [DiagnosticAppInstallation],
        selectedURL: URL?
    ) -> DesktopClientSelectionResult {
        let candidates = installations
            .filter { $0.bundleIdentifier == CodexIntegration.bundleIdentifier }
            .map {
                DesktopClientTarget(
                    appURL: $0.url,
                    processIdentifier: $0.processIdentifier,
                    isRunning: $0.isRunning,
                    selectionReason: .installedFallback
                )
            }
        let running = candidates.filter(\.isRunning)
        if running.count > 1 {
            return DesktopClientSelectionResult(
                status: .ambiguous,
                target: nil,
                candidates: running,
                unavailableReason: "检测到多个正在运行的 ChatGPT/Codex 主客户端"
            )
        }
        if let runningTarget = running.first {
            return selected(
                runningTarget,
                reason: .runningInstance,
                candidates: candidates
            )
        }

        let sorted = candidates.sorted {
            commandPreference($0.appURL) < commandPreference($1.appURL)
        }
        if let chatGPT = sorted.first(where: {
            $0.displayName.caseInsensitiveCompare("ChatGPT") == .orderedSame
        }) {
            return selected(chatGPT, reason: .chatGPTPreferred, candidates: candidates)
        }

        if let selectedPath = selectedURL?
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path,
           let systemSelected = sorted.first(where: { $0.appURL.path == selectedPath }) {
            return selected(
                systemSelected,
                reason: .systemSelection,
                candidates: candidates
            )
        }

        if let codex = sorted.first(where: {
            $0.displayName.caseInsensitiveCompare("Codex") == .orderedSame
        }) {
            return selected(
                codex,
                reason: .codexCompatibility,
                candidates: candidates
            )
        }

        if let fallback = sorted.first {
            return selected(
                fallback,
                reason: .installedFallback,
                candidates: candidates
            )
        }
        return DesktopClientSelectionResult(
            status: .unavailable,
            target: nil,
            candidates: [],
            unavailableReason: "未找到可用的 ChatGPT/Codex 桌面客户端"
        )
    }

    private static func selected(
        _ target: DesktopClientTarget,
        reason: DesktopClientSelectionReason,
        candidates: [DesktopClientTarget]
    ) -> DesktopClientSelectionResult {
        DesktopClientSelectionResult(
            status: .selected,
            target: DesktopClientTarget(
                appURL: target.appURL,
                processIdentifier: target.processIdentifier,
                isRunning: target.isRunning,
                selectionReason: reason
            ),
            candidates: candidates,
            unavailableReason: nil
        )
    }

    private static func commandPreference(_ url: URL) -> Int {
        switch url.path {
        case "/Applications/ChatGPT.app": 0
        case let path where path.hasSuffix("/Applications/ChatGPT.app"): 1
        case "/Applications/Codex.app": 2
        case let path where path.hasSuffix("/Applications/Codex.app"): 3
        default: 4
        }
    }
}

public enum DesktopClientRestartVerifier {
    public static func verify(
        previous: DesktopClientTarget?,
        current: DesktopClientTarget?
    ) -> Bool {
        guard
            let previous,
            let current,
            current.isRunning,
            current.processIdentifier != nil,
            previous.appURL == current.appURL
        else {
            return false
        }
        if let previousPID = previous.processIdentifier {
            return current.processIdentifier != previousPID
        }
        return true
    }
}
