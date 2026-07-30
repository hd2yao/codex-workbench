import Foundation

public struct WorkflowGitHistoryEvidence: Equatable, Sendable {
    public let previousSnapshot: WorkflowSemanticSnapshot?
    public let currentSnapshot: WorkflowSemanticSnapshot
    public let sourcePath: String
    public let commit: String

    public init(
        previousSnapshot: WorkflowSemanticSnapshot?,
        currentSnapshot: WorkflowSemanticSnapshot,
        sourcePath: String,
        commit: String
    ) {
        self.previousSnapshot = previousSnapshot
        self.currentSnapshot = currentSnapshot
        self.sourcePath = sourcePath
        self.commit = commit
    }
}

public struct WorkflowGitHistoryEvidenceCollector: Sendable {
    public static var standardSourceRoots: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("program/codex-workflow-skills", isDirectory: true),
        ]
    }

    public init() {}

    public func evidence(
        kind: WorkflowFileKind,
        label: String,
        afterFingerprint: String,
        sourceRoots: [URL]
    ) -> WorkflowGitHistoryEvidence? {
        guard [.skill, .hook].contains(kind) else { return nil }
        for sourceURL in candidates(kind: kind, label: label, roots: sourceRoots) {
            guard
                let repositoryRoot = repositoryRoot(containing: sourceURL),
                let relativePath = relativePath(of: sourceURL, in: repositoryRoot)
            else {
                continue
            }
            let log = runGit(
                ["log", "--format=%H", "--max-count=40", "--", relativePath],
                in: repositoryRoot
            )
            guard log.status == 0 else { continue }
            let commits = String(decoding: log.output, as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            for commit in commits {
                let currentBlob = runGit(["show", "\(commit):\(relativePath)"], in: repositoryRoot)
                guard
                    currentBlob.status == 0,
                    fingerprint(for: currentBlob.output) == afterFingerprint,
                    let currentSnapshot = snapshot(kind: kind, data: currentBlob.output)
                else {
                    continue
                }
                let previousBlob = runGit(["show", "\(commit)^:\(relativePath)"], in: repositoryRoot)
                let previousSnapshot = previousBlob.status == 0
                    ? snapshot(kind: kind, data: previousBlob.output)
                    : nil
                return WorkflowGitHistoryEvidence(
                    previousSnapshot: previousSnapshot,
                    currentSnapshot: currentSnapshot,
                    sourcePath: sourceURL.path,
                    commit: String(commit.prefix(12))
                )
            }
        }
        return nil
    }

    private func candidates(kind: WorkflowFileKind, label: String, roots: [URL]) -> [URL] {
        var result: Set<String> = []
        for root in roots {
            let direct: URL
            switch kind {
            case .skill:
                direct = root.appendingPathComponent(label, isDirectory: true).appendingPathComponent("SKILL.md")
            case .hook:
                direct = root.appendingPathComponent("\(label).py")
            default:
                continue
            }
            if FileManager.default.fileExists(atPath: direct.path) {
                result.insert(direct.standardizedFileURL.path)
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                let matches: Bool
                switch kind {
                case .skill:
                    matches = url.lastPathComponent == "SKILL.md"
                        && url.deletingLastPathComponent().lastPathComponent == label
                case .hook:
                    matches = url.lastPathComponent == "\(label).py"
                default:
                    matches = false
                }
                if matches {
                    result.insert(url.standardizedFileURL.path)
                }
            }
        }
        return result.sorted().map(URL.init(fileURLWithPath:))
    }

    private func repositoryRoot(containing fileURL: URL) -> URL? {
        let result = runGit(
            ["rev-parse", "--show-toplevel"],
            in: fileURL.deletingLastPathComponent()
        )
        guard result.status == 0 else { return nil }
        let path = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL
    }

    private func relativePath(of fileURL: URL, in repositoryRoot: URL) -> String? {
        let root = repositoryRoot.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func snapshot(kind: WorkflowFileKind, data: Data) -> WorkflowSemanticSnapshot? {
        let content = String(decoding: data, as: UTF8.self)
        switch kind {
        case .skill:
            return .skill(content: content)
        case .hook:
            return .hook(content: content)
        default:
            return nil
        }
    }

    private func fingerprint(for data: Data) -> String {
        StableEventID.make(parts: ["workflow-file", data.base64EncodedString()])
    }

    private func runGit(_ arguments: [String], in directory: URL) -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch {
            return (-1, Data())
        }
    }
}
