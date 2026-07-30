import Foundation

public final class WorkflowRolloutTextCache: @unchecked Sendable {
    public let maximumBytesPerFile: Int

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failedPaths: Set<String> = []

    public init(maximumBytesPerFile: Int = 8 * 1_024 * 1_024) {
        self.maximumBytesPerFile = max(1_024, maximumBytesPerFile)
    }

    public func text(at rawPath: String) -> String? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        lock.lock()
        if let cached = values[path] {
            lock.unlock()
            return cached
        }
        if failedPaths.contains(path) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let loaded = Self.readTail(path: path, maximumBytes: maximumBytesPerFile)
        lock.lock()
        if let loaded {
            values[path] = loaded
        } else {
            failedPaths.insert(path)
        }
        lock.unlock()
        return loaded
    }

    private static func readTail(path: String, maximumBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let fileSize = try handle.seekToEnd()
            let maximum = UInt64(maximumBytes)
            let offset = fileSize > maximum ? fileSize - maximum : 0
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: maximumBytes) ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if offset > 0 {
                guard let firstNewline = text.firstIndex(of: "\n") else { return "" }
                text = String(text[text.index(after: firstNewline)...])
            }
            return evidenceLines(in: text)
        } catch {
            return nil
        }
    }

    private static func evidenceLines(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine)
            if line.contains("custom_tool_call_output") {
                return line.contains("id =") && line.contains("prompt =") ? line : nil
            }
            if line.contains("custom_tool_call") {
                return line.contains("codex_app__automation_update")
                    || line.contains("*** Begin Patch")
                    ? line
                    : nil
            }
            return nil
        }.joined(separator: "\n")
    }
}
