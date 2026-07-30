import Darwin
import Foundation

public final class AutomaticResetClaim: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        self.descriptor = nil
    }

    deinit {
        release()
    }
}

public struct AutomaticResetClaimStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func shared(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(
            directoryURL: homeDirectory
                .appendingPathComponent(".codex/profile-switcher/automatic-reset-claims", isDirectory: true)
        )
    }

    public func acquire(fingerprint: String) -> AutomaticResetClaim? {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }

        let filename = StableEventID.make(parts: ["automatic-reset-claim", fingerprint]) + ".lock"
        let lockURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        let descriptor = lockURL.path.withCString {
            open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return AutomaticResetClaim(descriptor: descriptor)
    }
}
