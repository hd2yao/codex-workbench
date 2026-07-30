import CodexWorkbenchCore
import Foundation

func runAppServerNotificationTests(_ runner: inout TestRunner) {
    let update = Data(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":2}}}}"#.utf8)
    let other = Data(#"{"method":"account/updated","params":{"authMode":"chatgpt"}}"#.utf8)
    let response = Data(#"{"id":7,"result":{"rateLimits":{}}}"#.utf8)

    runner.expect(
        OfficialAppServerProtocol.isRateLimitsUpdatedNotification(update),
        "Official rate-limit notifications should be recognized exactly"
    )
    runner.expect(
        OfficialAppServerProtocol.isRateLimitsUpdatedNotification(other) == false,
        "Other account notifications should not trigger quota reconciliation"
    )
    runner.expect(
        OfficialAppServerProtocol.isRateLimitsUpdatedNotification(response) == false,
        "A request response should not be mistaken for a server notification"
    )

    let handshake = OfficialAppServerProtocol.handshakeData(
        clientName: "codex-observatory",
        version: "1"
    )
    let lines = String(decoding: handshake, as: UTF8.self)
        .split(separator: "\n")
        .map(String.init)
    runner.expect(lines.count == 3, "Observer handshake should initialize, acknowledge, then read rate limits")
    runner.expect(lines[0].contains(#""method":"initialize""#), "First handshake message should initialize")
    runner.expect(lines[0].contains(#""name":"codex-observatory""#), "Handshake should identify the client")
    runner.expect(lines[1].contains(#""method":"initialized""#), "Second handshake message should acknowledge initialization")
    runner.expect(lines[2].contains(#""method":"account/rateLimits/read""#), "Handshake should request a full initial snapshot")
}
