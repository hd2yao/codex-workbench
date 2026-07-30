import Foundation

public struct LedgerWriteResult: Equatable, Sendable {
    public let appendedCount: Int
    public let warnings: [String]

    public init(appendedCount: Int, warnings: [String] = []) {
        self.appendedCount = appendedCount
        self.warnings = warnings
    }
}

public struct LedgerWriter: Sendable {
    public init() {}

    public func append(events: [OperationEvent], to fileURL: URL) -> LedgerWriteResult {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var knownIDs = Set<String>()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                knownIDs.formUnion(LedgerRepository().load(from: fileURL, limit: .max).events.map(\.id))
            }

            let encoder = Self.encoder()
            var payload = Data()
            var appendedCount = 0
            for event in events.sorted(by: { $0.occurredAt < $1.occurredAt }) where knownIDs.insert(event.id).inserted {
                payload.append(try encoder.encode(event))
                payload.append(0x0A)
                appendedCount += 1
            }
            guard !payload.isEmpty else { return LedgerWriteResult(appendedCount: 0) }

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.close()
            return LedgerWriteResult(appendedCount: appendedCount)
        } catch {
            return LedgerWriteResult(appendedCount: 0, warnings: ["无法写入操作日志。"])
        }
    }

    public func appendRevisions(events: [OperationEvent], to fileURL: URL) -> LedgerWriteResult {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let latestByID = Dictionary(
                uniqueKeysWithValues: LedgerRepository()
                    .load(from: fileURL, limit: .max)
                    .events
                    .map { ($0.id, $0) }
            )
            let revisions = events.filter { candidate in
                guard let latest = latestByID[candidate.id] else { return true }
                return candidate.recordedAt > latest.recordedAt && candidate != latest
            }
            guard !revisions.isEmpty else { return LedgerWriteResult(appendedCount: 0) }

            let encoder = Self.encoder()
            var payload = Data()
            for event in revisions.sorted(by: { $0.occurredAt < $1.occurredAt }) {
                payload.append(try encoder.encode(event))
                payload.append(0x0A)
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.close()
            return LedgerWriteResult(appendedCount: revisions.count)
        } catch {
            return LedgerWriteResult(appendedCount: 0, warnings: ["无法写入操作日志增强版本。"])
        }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}
