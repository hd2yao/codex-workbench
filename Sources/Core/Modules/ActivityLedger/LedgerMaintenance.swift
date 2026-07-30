import Foundation

public struct LedgerPruneResult: Equatable, Sendable {
    public let removedCount: Int
    public let warnings: [String]

    public init(removedCount: Int, warnings: [String] = []) {
        self.removedCount = removedCount
        self.warnings = warnings
    }
}

public struct LedgerMaintenance: Sendable {
    public init() {}

    public func prune(actions: Set<String>, from fileURL: URL) -> LedgerPruneResult {
        guard !actions.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) else {
            return LedgerPruneResult(removedCount: 0)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            var kept: [String] = []
            var removedCount = 0
            for rawLine in lines {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if
                    !trimmed.isEmpty,
                    let event = try? LedgerRepository.decoder().decode(
                        OperationEvent.self,
                        from: Data(trimmed.utf8)
                    ),
                    actions.contains(event.action)
                {
                    removedCount += 1
                    continue
                }
                kept.append(line)
            }
            guard removedCount > 0 else {
                return LedgerPruneResult(removedCount: 0)
            }
            try Data(kept.joined(separator: "\n").utf8).write(to: fileURL, options: .atomic)
            return LedgerPruneResult(removedCount: removedCount)
        } catch {
            return LedgerPruneResult(
                removedCount: 0,
                warnings: ["无法清理旧版额度状态噪声。"]
            )
        }
    }
}
