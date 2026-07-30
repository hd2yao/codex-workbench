import Foundation

public enum OfficialAppServerProtocol {
    public static func isRateLimitsUpdatedNotification(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["id"] == nil,
            let method = object["method"] as? String
        else {
            return false
        }
        return method == "account/rateLimits/updated"
    }

    public static func handshakeData(clientName: String, version: String) -> Data {
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": clientName, "version": version],
                    "capabilities": ["experimentalApi": true],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [:],
            ],
            [
                "jsonrpc": "2.0",
                "id": 7,
                "method": "account/rateLimits/read",
                "params": [:],
            ],
        ]

        let lines = messages.compactMap { message -> String? in
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: message,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
