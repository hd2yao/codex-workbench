import Foundation

public enum AccountOperationEventFactory {
    public static func switchSucceeded(
        from previousProfile: String?,
        to profile: String,
        clientDisplayName: String = "桌面客户端",
        at date: Date = Date()
    ) -> OperationEvent {
        let client = safeClientDisplayName(clientDisplayName)
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "account-switch",
                "success",
                profile,
                timestamp(date),
            ]),
            occurredAt: date,
            recordedAt: date,
            category: .account,
            action: "account_switched",
            title: "已切换 \(client) 账号",
            summary: "工作台已把 \(profile) 设为 \(client) 的预期桌面默认账号；当前无法独立证明该进程已加载此账号。",
            status: .success,
            importance: .critical,
            certainty: .inferred,
            actor: workbenchActor,
            account: EventAccount(profile: profile),
            sourceChain: [workbenchActor, accountEngineActor],
            before: previousProfile.map { .object(["desktop_profile": .string($0)]) },
            after: .object(["desktop_profile": .string(profile)]),
            evidence: [EventEvidence(kind: "app_action", label: "默认账号切换并重启完成")]
        )
    }

    public static func switchFailed(
        expected: String,
        actual: String?,
        reason: String,
        clientDisplayName: String = "桌面客户端",
        at date: Date = Date()
    ) -> OperationEvent {
        let client = safeClientDisplayName(clientDisplayName)
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "account-switch",
                "failure",
                expected,
                reason,
                timestamp(date),
            ]),
            occurredAt: date,
            recordedAt: date,
            category: .account,
            action: "account_switch_failed",
            title: "\(client) 账号切换未完成",
            summary: "账号切换未通过验证：目标 \(expected)，实际 \(actual ?? "未知")。",
            status: .failure,
            importance: .critical,
            certainty: .confirmed,
            actor: workbenchActor,
            account: EventAccount(profile: expected),
            sourceChain: [workbenchActor, accountEngineActor],
            after: actual.map { .object(["actual_profile": .string($0)]) },
            evidence: [EventEvidence(kind: "app_action", label: failureEvidenceLabel(reason))]
        )
    }

    public static func restartSucceeded(
        profile: String?,
        clientDisplayName: String = "桌面客户端",
        at date: Date = Date()
    ) -> OperationEvent {
        let client = safeClientDisplayName(clientDisplayName)
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "account-restart",
                "success",
                profile ?? "unknown",
                timestamp(date),
            ]),
            occurredAt: date,
            recordedAt: date,
            category: .account,
            action: "account_restarted",
            title: "已重启 \(client)",
            summary: "工作台已安全重启 \(client)，Codex Home 中的预期默认账号保持不变。",
            status: .success,
            importance: .important,
            certainty: .inferred,
            actor: workbenchActor,
            account: EventAccount(profile: profile),
            sourceChain: [workbenchActor, accountEngineActor],
            evidence: [EventEvidence(kind: "app_action", label: "精确客户端重启完成")]
        )
    }

    public static func restartFailed(
        profile: String?,
        reason: String,
        clientDisplayName: String = "桌面客户端",
        at date: Date = Date()
    ) -> OperationEvent {
        let client = safeClientDisplayName(clientDisplayName)
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "account-restart",
                "failure",
                profile ?? "unknown",
                safeRestartReason(reason),
                timestamp(date),
            ]),
            occurredAt: date,
            recordedAt: date,
            category: .account,
            action: "account_restart_failed",
            title: "\(client) 重启未完成",
            summary: "工作台未能完成安全重启，当前账号状态仍需确认。",
            status: .failure,
            importance: .important,
            certainty: .confirmed,
            actor: workbenchActor,
            account: EventAccount(profile: profile),
            sourceChain: [workbenchActor, accountEngineActor],
            evidence: [
                EventEvidence(kind: "app_action", label: restartFailureEvidenceLabel(reason))
            ]
        )
    }

    public static func restartCancelled(
        profile: String?,
        clientDisplayName: String = "桌面客户端",
        at date: Date = Date()
    ) -> OperationEvent {
        let client = safeClientDisplayName(clientDisplayName)
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "account-restart",
                "cancelled",
                profile ?? "unknown",
                timestamp(date),
            ]),
            occurredAt: date,
            recordedAt: date,
            category: .account,
            action: "restart_cancelled",
            title: "已取消 \(client) 重启",
            summary: "保留当前 \(client) 运行状态，未执行退出或启动操作。",
            status: .skipped,
            importance: .routine,
            certainty: .confirmed,
            actor: workbenchActor,
            account: EventAccount(profile: profile),
            sourceChain: [workbenchActor],
            evidence: [EventEvidence(kind: "app_action", label: "用户取消风险确认")]
        )
    }

    private static let workbenchActor = EventActor(
        type: .app,
        id: "codex-workbench",
        label: "Codex 工作台"
    )

    private static let accountEngineActor = EventActor(
        type: .system,
        id: "codex-profile-switcher",
        label: "Profile Switcher 账号引擎"
    )

    private static func failureEvidenceLabel(_ reason: String) -> String {
        switch reason {
        case "switch_command_failed": "账号切换命令失败"
        case "verification_unavailable": "无法读取切换后状态"
        case "verification_mismatch": "切换后账号不匹配"
        case "unmanaged_login": "切换后账号未被工作台接管"
        default: "账号切换未通过验证"
        }
    }

    private static func safeRestartReason(_ reason: String) -> String {
        switch reason {
        case "restart_command_failed", "verification_unavailable", "verification_mismatch",
             "desktop_identity_mismatch":
            reason
        default: "unknown"
        }
    }

    private static func restartFailureEvidenceLabel(_ reason: String) -> String {
        switch safeRestartReason(reason) {
        case "restart_command_failed": "安全重启命令失败"
        case "verification_unavailable": "无法读取重启后状态"
        case "verification_mismatch": "重启后账号不匹配"
        case "desktop_identity_mismatch": "桌面客户端进程身份不匹配"
        default: "安全重启未通过验证"
        }
    }

    private static func safeClientDisplayName(_ value: String) -> String {
        switch value {
        case "ChatGPT": "ChatGPT"
        case "Codex": "Codex"
        default: "桌面客户端"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }
}
