import Foundation

public enum CodexIntegration {
    public static let bundleIdentifier = "com.openai.codex"

    public static func threadURL(for threadID: String) -> URL? {
        guard let uuid = UUID(uuidString: threadID) else { return nil }
        return URL(string: "codex://threads/\(uuid.uuidString.lowercased())")
    }
}
