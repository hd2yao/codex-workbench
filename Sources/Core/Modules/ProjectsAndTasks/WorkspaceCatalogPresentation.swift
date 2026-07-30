import Foundation

public struct WorkspaceThreadPresentation: Equatable, Sendable {
    public let id: String
    public let title: String
    public let projectName: String
    public let projectPath: String
    public let updatedAt: Date
    public let sourceThreadID: String?
    public let sourceThreadTitle: String?
    public let hasContextSummary: Bool
    public let contextTopic: String?

    public init(
        id: String,
        title: String,
        projectName: String,
        projectPath: String,
        updatedAt: Date,
        sourceThreadID: String?,
        sourceThreadTitle: String?,
        hasContextSummary: Bool,
        contextTopic: String?
    ) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.projectPath = projectPath
        self.updatedAt = updatedAt
        self.sourceThreadID = sourceThreadID
        self.sourceThreadTitle = sourceThreadTitle
        self.hasContextSummary = hasContextSummary
        self.contextTopic = contextTopic
    }
}

public struct WorkspaceProjectPresentation: Equatable, Sendable {
    public let name: String
    public let path: String
    public let updatedAt: Date
    public let threads: [WorkspaceThreadPresentation]

    public init(
        name: String,
        path: String,
        updatedAt: Date,
        threads: [WorkspaceThreadPresentation]
    ) {
        self.name = name
        self.path = path
        self.updatedAt = updatedAt
        self.threads = threads
    }
}

public enum WorkflowAssetSource: String, Equatable, Sendable {
    case sourceTree
    case installedCopy
    case localFile

    public var title: String {
        switch self {
        case .sourceTree: "源码"
        case .installedCopy: "已安装"
        case .localFile: "本机配置"
        }
    }
}

public enum WorkflowAssetCopyState: String, Equatable, Sendable {
    case singleCopy
    case matchingCopies
    case mismatchedCopies

    public var title: String {
        switch self {
        case .singleCopy: "单一副本"
        case .matchingCopies: "副本一致"
        case .mismatchedCopies: "副本有差异"
        }
    }
}

public struct WorkflowItemPresentation: Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String?
    public let schedule: String?
    public let purpose: String?
    public let modifiedAt: Date
    public let kind: WorkflowFileKind
    public let source: WorkflowAssetSource
    public let copyState: WorkflowAssetCopyState

    public init(
        id: String,
        name: String,
        status: String?,
        schedule: String?,
        purpose: String?,
        modifiedAt: Date,
        kind: WorkflowFileKind = .configuration,
        source: WorkflowAssetSource = .localFile,
        copyState: WorkflowAssetCopyState = .singleCopy
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.schedule = schedule
        self.purpose = purpose
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.source = source
        self.copyState = copyState
    }
}

public struct WorkflowCatalogPresentation: Equatable, Sendable {
    public let hooks: [WorkflowItemPresentation]
    public let automations: [WorkflowItemPresentation]
    public let assets: [WorkflowItemPresentation]

    public init(
        hooks: [WorkflowItemPresentation],
        automations: [WorkflowItemPresentation],
        assets: [WorkflowItemPresentation]? = nil
    ) {
        self.hooks = hooks
        self.automations = automations
        self.assets = assets ?? hooks + automations
    }
}

public struct WorkspaceCatalogPresentation: Equatable, Sendable {
    public let projects: [WorkspaceProjectPresentation]
    public let recentThreads: [WorkspaceThreadPresentation]
    public let contextSummaryCount: Int
    public let workflows: WorkflowCatalogPresentation

    public init(
        projects: [WorkspaceProjectPresentation],
        recentThreads: [WorkspaceThreadPresentation],
        contextSummaryCount: Int,
        workflows: WorkflowCatalogPresentation
    ) {
        self.projects = projects
        self.recentThreads = recentThreads
        self.contextSummaryCount = contextSummaryCount
        self.workflows = workflows
    }
}

public enum WorkspaceCatalogPresentationBuilder {
    public static func build(
        catalog: CodexMetadataCatalog,
        contextCards: [ContextCardEvidence],
        workflowFiles: [WorkflowFileFingerprint]
    ) -> WorkspaceCatalogPresentation {
        let latestCardByThread = latestCardsByThread(contextCards)
        let recentThreads = catalog.records.map { thread in
            let card = latestCardByThread[thread.id]
            return WorkspaceThreadPresentation(
                id: thread.id,
                title: thread.title,
                projectName: thread.projectName,
                projectPath: thread.projectPath,
                updatedAt: thread.updatedAt,
                sourceThreadID: thread.sourceThreadID,
                sourceThreadTitle: thread.sourceThreadID.flatMap { catalog.thread(id: $0)?.title },
                hasContextSummary: card != nil,
                contextTopic: card?.summary.topic
            )
        }

        let grouped = Dictionary(grouping: recentThreads, by: \.projectPath)
        let projects = grouped.map { path, threads in
            let sorted = threads.sorted { $0.updatedAt > $1.updatedAt }
            return WorkspaceProjectPresentation(
                name: sorted.first?.projectName
                    ?? URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                updatedAt: sorted.first?.updatedAt ?? .distantPast,
                threads: sorted
            )
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.path < $1.path
        }

        let assets = workflowAssets(files: workflowFiles)
        return WorkspaceCatalogPresentation(
            projects: projects,
            recentThreads: recentThreads,
            contextSummaryCount: latestCardByThread.count,
            workflows: WorkflowCatalogPresentation(
                hooks: assets.filter { $0.kind == .hook },
                automations: assets.filter { $0.kind == .automation },
                assets: assets
            )
        )
    }

    private static func latestCardsByThread(
        _ cards: [ContextCardEvidence]
    ) -> [String: ContextCardEvidence] {
        var result: [String: ContextCardEvidence] = [:]
        for card in cards {
            if let existing = result[card.threadID], existing.generatedAt >= card.generatedAt {
                continue
            }
            result[card.threadID] = card
        }
        return result
    }

    private static func workflowAssets(
        files: [WorkflowFileFingerprint]
    ) -> [WorkflowItemPresentation] {
        let nonSkills = files.filter { $0.kind != .skill }.map(assetItem)
        let skillGroups = Dictionary(
            grouping: files.filter { $0.kind == .skill },
            by: { $0.label.lowercased() }
        )
        let skills = skillGroups.map { slug, copies in
            skillItem(slug: slug, copies: copies)
        }
        return (nonSkills + skills).sorted { lhs, rhs in
            assetSort(lhs: lhs, rhs: rhs)
        }
    }

    private static func assetItem(_ file: WorkflowFileFingerprint) -> WorkflowItemPresentation {
        WorkflowItemPresentation(
            id: file.path,
            name: file.semanticSnapshot?.name ?? file.label,
            status: file.semanticSnapshot?.status,
            schedule: file.semanticSnapshot?.schedule,
            purpose: file.semanticSnapshot?.purpose,
            modifiedAt: file.modifiedAt,
            kind: file.kind,
            source: assetSource(path: file.path),
            copyState: .singleCopy
        )
    }

    private static func skillItem(
        slug: String,
        copies: [WorkflowFileFingerprint]
    ) -> WorkflowItemPresentation {
        let preferred = copies.sorted { lhs, rhs in
            let lhsScore = semanticPreferenceScore(lhs)
            let rhsScore = semanticPreferenceScore(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.path < rhs.path
        }.first!
        let fingerprints = Set(copies.map(\.fingerprint))
        let copyState: WorkflowAssetCopyState
        if copies.count == 1 {
            copyState = .singleCopy
        } else if fingerprints.count == 1 {
            copyState = .matchingCopies
        } else {
            copyState = .mismatchedCopies
        }
        return WorkflowItemPresentation(
            id: "skill:\(slug)",
            name: preferred.semanticSnapshot?.name ?? preferred.label,
            status: preferred.semanticSnapshot?.status,
            schedule: preferred.semanticSnapshot?.schedule,
            purpose: preferred.semanticSnapshot?.purpose,
            modifiedAt: copies.map(\.modifiedAt).max() ?? preferred.modifiedAt,
            kind: .skill,
            source: assetSource(path: preferred.path),
            copyState: copyState
        )
    }

    private static func semanticPreferenceScore(_ file: WorkflowFileFingerprint) -> Int {
        let hasSemanticSnapshot = file.semanticSnapshot == nil ? 0 : 2
        let installed = assetSource(path: file.path) == .installedCopy ? 1 : 0
        return installed + hasSemanticSnapshot
    }

    private static func assetSource(path: String) -> WorkflowAssetSource {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        if normalized.contains("/.codex/skills/")
            || normalized.contains("/.agents/skills/")
            || normalized.contains("/.claude/skills/") {
            return .installedCopy
        }
        if normalized.contains("/program/codex-workflow-skills/")
            || normalized.contains("/program/skills/") {
            return .sourceTree
        }
        return .localFile
    }

    private static func assetSort(
        lhs: WorkflowItemPresentation,
        rhs: WorkflowItemPresentation
    ) -> Bool {
        let lhsKind = WorkflowFileKind.allCases.firstIndex(of: lhs.kind) ?? .max
        let rhsKind = WorkflowFileKind.allCases.firstIndex(of: rhs.kind) ?? .max
        if lhsKind != rhsKind { return lhsKind < rhsKind }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.name != rhs.name { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
        return lhs.id < rhs.id
    }
}
