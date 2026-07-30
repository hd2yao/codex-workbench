import CodexWorkbenchCore
import Darwin
import Foundation

@MainActor
final class OfficialRateLimitObserver {
    private var process: Process?
    private var readerTask: Task<Void, Never>?
    private var observedProfileHome: String?

    var isRunning: Bool { process?.isRunning == true }

    func start(
        profileHome: String,
        onRateLimitsUpdated: @escaping @MainActor @Sendable () -> Void
    ) {
        if observedProfileHome == profileHome, process?.isRunning == true {
            return
        }
        stop()

        guard let executableURL = Self.resolveCodexExecutable() else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profileHome
        process.environment = environment

        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(
                contentsOf: OfficialAppServerProtocol.handshakeData(
                    clientName: "codex-observatory",
                    version: "1"
                )
            )
        } catch {
            process.terminate()
            return
        }

        self.process = process
        observedProfileHome = profileHome
        readerTask = Task.detached(priority: .utility) {
            do {
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    guard OfficialAppServerProtocol.isRateLimitsUpdatedNotification(Data(line.utf8)) else {
                        continue
                    }
                    await onRateLimitsUpdated()
                }
            } catch {
                return
            }
        }
    }

    func stop() {
        readerTask?.cancel()
        readerTask = nil
        if let child = process, child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if child.isRunning {
                Darwin.kill(child.processIdentifier, SIGKILL)
            }
        }
        process = nil
        observedProfileHome = nil
    }

    private static func resolveCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ]
        if let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }

        guard
            let pathValue = ProcessInfo.processInfo.environment["PATH"]
        else {
            return nil
        }
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
