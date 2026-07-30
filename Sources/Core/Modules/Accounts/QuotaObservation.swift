import Foundation

public struct QuotaObservation: Codable, Equatable, Sendable {
    public let profile: String
    public let observedAt: Date
    public let remainingPercent: Double?
    public let resetsAt: Date?
    public let resetCredits: Int?
    public let reachedType: String?

    public init(
        profile: String,
        observedAt: Date,
        remainingPercent: Double?,
        resetsAt: Date?,
        resetCredits: Int?,
        reachedType: String?
    ) {
        self.profile = profile
        self.observedAt = observedAt
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.resetCredits = resetCredits
        self.reachedType = reachedType
    }

    public func hasSameState(as other: QuotaObservation) -> Bool {
        profile == other.profile
            && remainingPercent == other.remainingPercent
            && resetsAt == other.resetsAt
            && resetCredits == other.resetCredits
            && reachedType == other.reachedType
    }
}

public struct QuotaEventFactory: Sendable {
    public let scheduledLeadTime: TimeInterval
    public let scheduledLagTime: TimeInterval
    public let localResetCorrelationWindow: TimeInterval

    public init(
        scheduledLeadTime: TimeInterval = 5 * 60,
        scheduledLagTime: TimeInterval = 15 * 60,
        localResetCorrelationWindow: TimeInterval = 5 * 60
    ) {
        self.scheduledLeadTime = scheduledLeadTime
        self.scheduledLagTime = scheduledLagTime
        self.localResetCorrelationWindow = localResetCorrelationWindow
    }

    public func events(
        previous: QuotaObservation,
        current: QuotaObservation,
        localResetEvents: [OperationEvent] = []
    ) -> [OperationEvent] {
        guard !previous.hasSameState(as: current) else { return [] }

        let localReset = matchingLocalReset(
            profile: current.profile,
            observedAt: current.observedAt,
            events: localResetEvents
        )
        let recovered = (previous.remainingPercent ?? 100) < 99
            && (current.remainingPercent ?? 0) >= 99
        var result: [OperationEvent] = []

        if recovered {
            if localReset != nil {
                result.append(makeEvent(
                    action: "quota_restored_by_credit",
                    title: "已使用重置次数恢复额度",
                    summary: "\(current.profile) 的额度已恢复，并与本地重置次数消费记录对应。",
                    status: .success,
                    importance: .critical,
                    certainty: .confirmed,
                    previous: previous,
                    current: current,
                    evidenceLabel: "官方额度快照 + 本地重置记录"
                ))
            } else if isScheduledRefresh(previous: previous, observedAt: current.observedAt) {
                result.append(makeEvent(
                    action: "quota_window_refreshed",
                    title: "额度已按计划刷新",
                    summary: "\(current.profile) 在原定刷新时间附近恢复至 \(Self.percentText(current.remainingPercent))。",
                    status: .success,
                    importance: .routine,
                    certainty: .inferred,
                    previous: previous,
                    current: current,
                    evidenceLabel: "官方额度快照 + 原定刷新时间"
                ))
            } else {
                result.append(makeEvent(
                    action: "official_quota_restored",
                    title: "检测到官方侧额度恢复",
                    summary: "\(current.profile) 在原定刷新窗口外恢复至 \(Self.percentText(current.remainingPercent))；官方未提供原因。",
                    status: .success,
                    importance: .important,
                    certainty: .inferred,
                    previous: previous,
                    current: current,
                    evidenceLabel: "官方额度快照差异"
                ))
            }
        }

        if previous.resetCredits != current.resetCredits,
           let before = previous.resetCredits,
           let after = current.resetCredits,
           !(localReset != nil && after < before) {
            let increased = after > before
            result.append(makeEvent(
                action: increased ? "reset_credits_increased" : "reset_credits_decreased",
                title: increased ? "官方重置次数已增加" : "检测到重置次数减少",
                summary: increased
                    ? "\(current.profile) 的重置次数由 \(before) 次增加到 \(after) 次；官方未提供原因。"
                    : "\(current.profile) 的重置次数由 \(before) 次减少到 \(after) 次。",
                status: .success,
                importance: .important,
                certainty: .confirmed,
                previous: previous,
                current: current,
                evidenceLabel: "官方重置次数快照差异"
            ))
        }

        let wasExhausted = previous.reachedType != nil || (previous.remainingPercent ?? 1) <= 0
        let isExhausted = current.reachedType != nil || (current.remainingPercent ?? 1) <= 0
        if !recovered, wasExhausted != isExhausted {
            result.append(makeEvent(
                action: isExhausted ? "quota_limit_reached" : "quota_limit_cleared",
                title: isExhausted ? "额度已用完" : "额度限制已解除",
                summary: isExhausted
                    ? "\(current.profile) 已达到 \(current.reachedType ?? "额度") 限制。"
                    : "\(current.profile) 的额度限制状态已解除。",
                status: isExhausted ? .failure : .success,
                importance: isExhausted ? .critical : .routine,
                certainty: .confirmed,
                previous: previous,
                current: current,
                evidenceLabel: "官方达限状态"
            ))
        }

        return result.sorted { $0.action < $1.action }
    }

    private func isScheduledRefresh(previous: QuotaObservation, observedAt: Date) -> Bool {
        guard let resetsAt = previous.resetsAt else { return false }
        return observedAt >= resetsAt.addingTimeInterval(-scheduledLeadTime)
            && observedAt <= resetsAt.addingTimeInterval(scheduledLagTime)
    }

    private func matchingLocalReset(
        profile: String,
        observedAt: Date,
        events: [OperationEvent]
    ) -> OperationEvent? {
        events.first {
            $0.action == "reset_credit_consumed"
                && $0.status == .success
                && $0.account?.profile == profile
                && abs($0.occurredAt.timeIntervalSince(observedAt)) <= localResetCorrelationWindow
        }
    }

    private func makeEvent(
        action: String,
        title: String,
        summary: String,
        status: EventStatus,
        importance: EventImportance,
        certainty: EventCertainty,
        previous: QuotaObservation,
        current: QuotaObservation,
        evidenceLabel: String
    ) -> OperationEvent {
        OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "quota-observation",
                current.profile,
                action,
                Self.timestamp(current.observedAt),
            ]),
            occurredAt: current.observedAt,
            recordedAt: current.observedAt,
            category: .quota,
            action: action,
            title: title,
            summary: summary,
            status: status,
            importance: importance,
            certainty: certainty,
            actor: EventActor(type: .system, id: "codex-app-server", label: "Codex 官方额度"),
            account: EventAccount(profile: current.profile),
            sourceChain: [
                EventActor(type: .system, id: "codex-app-server", label: "Codex app-server"),
                EventActor(type: .system, id: "quota-state-diff", label: "额度状态差异"),
            ],
            before: Self.stateValue(previous),
            after: Self.stateValue(current),
            evidence: [EventEvidence(kind: "official_rate_limits", label: evidenceLabel)]
        )
    }

    private static func stateValue(_ observation: QuotaObservation) -> JSONValue {
        .object([
            "remaining_percent": observation.remainingPercent.map(JSONValue.number) ?? .null,
            "resets_at": observation.resetsAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "reset_credits": observation.resetCredits.map { .number(Double($0)) } ?? .null,
            "reached_type": observation.reachedType.map(JSONValue.string) ?? .null,
        ])
    }

    private static func timestamp(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }

    private static func percentText(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}
