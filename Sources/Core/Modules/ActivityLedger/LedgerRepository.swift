import Foundation

public struct LedgerWarning: Equatable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

public struct LedgerLoadResult: Equatable, Sendable {
    public let events: [OperationEvent]
    public let warnings: [LedgerWarning]

    public init(events: [OperationEvent], warnings: [LedgerWarning]) {
        self.events = events
        self.warnings = warnings
    }
}

public struct LedgerRepository: Sendable {
    public init() {}

    public func load(from fileURL: URL, limit: Int = 2_000) -> LedgerLoadResult {
        do {
            return load(data: try Data(contentsOf: fileURL), limit: limit)
        } catch {
            return LedgerLoadResult(
                events: [],
                warnings: [LedgerWarning(line: 0, message: "无法读取操作日志文件。")]
            )
        }
    }

    public func load(data: Data, limit: Int = 2_000) -> LedgerLoadResult {
        let text = String(decoding: data, as: UTF8.self)
        var eventsByID: [String: OperationEvent] = [:]
        var warnings: [LedgerWarning] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            do {
                let event = try Self.decoder().decode(OperationEvent.self, from: Data(line.utf8))
                if let existing = eventsByID[event.id], existing.recordedAt > event.recordedAt {
                    continue
                }
                eventsByID[event.id] = event
            } catch {
                warnings.append(LedgerWarning(line: index + 1, message: "无法解码该行事件。"))
            }
        }

        let safeLimit = max(0, limit)
        let sorted = eventsByID.values.sorted {
            if $0.occurredAt == $1.occurredAt {
                return $0.recordedAt > $1.recordedAt
            }
            return $0.occurredAt > $1.occurredAt
        }
        return LedgerLoadResult(events: Array(sorted.prefix(safeLimit)), warnings: warnings)
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) ?? standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 timestamp"
            )
        }
        return decoder
    }
}
