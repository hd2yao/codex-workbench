import Foundation

public enum StableEventID {
    public static func make(parts: [String]) -> String {
        let bytes = parts.joined(separator: "\u{1F}").utf8
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "evt_" + String(format: "%016llx", hash)
    }
}

public struct ContextCardEventFactory: Sendable {
    public init() {}

    public func event(
        from evidence: ContextCardEvidence,
        catalog: CodexMetadataCatalog,
        recordedAt: Date
    ) -> OperationEvent {
        let metadata = catalog.thread(id: evidence.threadID)
        let projectPath = metadata?.projectPath ?? evidence.projectPath
        let project = projectPath.map {
            EventProject(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0)
        }
        let changes = summaryChanges(from: evidence.summary)
        let listSummary = evidence.summary.recentUserRequest
            ?? evidence.summary.topic
            ?? evidence.summary.recentAssistantProgress.last
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "context-card",
                evidence.threadID,
                String(format: "%.6f", evidence.generatedAt.timeIntervalSince1970),
            ]),
            occurredAt: evidence.generatedAt,
            recordedAt: recordedAt,
            category: .context,
            action: "context_compacted",
            title: "上下文已压缩",
            summary: listSummary.map { "压缩后保留：\(Self.listExcerpt($0))" }
                ?? "PreCompact 已生成中文摘要卡片，但卡片中没有可显示的主题或进展。",
            status: .success,
            importance: .routine,
            certainty: .confirmed,
            actor: EventActor(type: .hook, id: "codex-context-summary-hook", label: "PreCompact Hook"),
            thread: EventThread(id: evidence.threadID, title: metadata?.title, relation: .triggeredBy),
            project: project,
            changes: changes,
            sourceChain: [
                EventActor(type: .system, id: "pre-compact", label: evidence.trigger),
                EventActor(type: .hook, id: "codex-context-summary-hook", label: "上下文摘要 Hook"),
            ],
            evidence: [
                EventEvidence(kind: "context_card", label: "上下文摘要卡片", path: evidence.sourcePath),
            ]
        )
    }

    private func summaryChanges(from summary: ContextCardSummary) -> [EventChange] {
        var result: [EventChange] = []
        if let topic = summary.topic {
            result.append(EventChange(label: "当前主题", summary: topic))
        }
        if let request = summary.recentUserRequest {
            result.append(EventChange(label: "最近用户要求", summary: request))
        }
        for progress in summary.recentAssistantProgress {
            result.append(EventChange(label: "压缩前进展", summary: progress))
        }
        return result
    }

    private static func listExcerpt(_ value: String) -> String {
        value.count <= 150 ? value : String(value.prefix(147)) + "…"
    }
}

public struct ContextEventHistoryEnricher: Sendable {
    public init() {}

    public func revisions(
        events: [OperationEvent],
        cards: [ContextCardEvidence],
        catalog: CodexMetadataCatalog,
        recordedAt: Date
    ) -> [OperationEvent] {
        var candidates: [String: OperationEvent] = [:]
        for card in cards {
            let event = ContextCardEventFactory().event(
                from: card,
                catalog: catalog,
                recordedAt: recordedAt
            )
            candidates[event.id] = event
        }
        return events.compactMap { event in
            let existingChanges = event.changes ?? []
            guard
                event.action == "context_compacted",
                let revision = candidates[event.id],
                let revisionChanges = revision.changes,
                !revisionChanges.isEmpty
            else {
                return nil
            }
            let existingLabels = Set(existingChanges.map(\.label))
            let addsMissingSummary = revisionChanges.contains {
                ["当前主题", "最近用户要求"].contains($0.label)
                    && !existingLabels.contains($0.label)
            }
            let needsRevision = existingChanges.isEmpty
                || existingChanges.contains { ContextCardSummary.isInjectedPreview($0.summary) }
                || addsMissingSummary
            guard
                needsRevision,
                !isSemanticallyEquivalent(revision, to: event)
            else {
                return nil
            }
            return revision
        }
    }

    private func isSemanticallyEquivalent(_ lhs: OperationEvent, to rhs: OperationEvent) -> Bool {
        lhs.summary == rhs.summary
            && lhs.thread == rhs.thread
            && lhs.project == rhs.project
            && lhs.changes == rhs.changes
            && lhs.evidence == rhs.evidence
    }
}

public struct EvidenceReconciler: Sendable {
    public init() {}

    public func events(from snapshot: EvidenceSnapshot, recordedAt: Date = Date()) -> [OperationEvent] {
        let contextEvents = snapshot.contextCards.map {
            ContextCardEventFactory().event(from: $0, catalog: snapshot.threadCatalog, recordedAt: recordedAt)
        }
        let resetEvents = snapshot.automaticResets.map { resetEvent(from: $0, recordedAt: recordedAt) }
        let lifecycleEvents = snapshot.lifecycleRecords.map {
            lifecycleEvent(from: $0, catalog: snapshot.threadCatalog, recordedAt: recordedAt)
        }
        let digestEvents = snapshot.dailyDigests.map {
            DailyDigestEventFactory().event(from: $0, recordedAt: recordedAt)
        }
        return (contextEvents + resetEvents + lifecycleEvents + digestEvents)
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func resetEvent(from evidence: AutomaticResetEvidence, recordedAt: Date) -> OperationEvent {
        let succeeded = evidence.outcome == "reset"
        let producedByWorkbench = evidence.producer == "codex-workbench"
        let producer = producedByWorkbench
            ? EventActor(type: .app, id: "codex-workbench", label: "Codex 工作台")
            : EventActor(type: .app, id: "codex-profile-switcher", label: "Profile Switcher")
        let producerLabel = producer.id == "codex-workbench" ? "工作台" : "Profile Switcher"
        let sourceChain = producedByWorkbench
            ? [
                producer,
                EventActor(
                    type: .system,
                    id: "codex-profile-switcher",
                    label: "Profile Switcher 账号引擎"
                ),
                EventActor(type: .system, id: "automatic-reset", label: "自动重置状态机"),
            ]
            : [
                producer,
                EventActor(type: .system, id: "automatic-reset", label: "自动重置状态机"),
            ]
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "automatic-reset",
                evidence.profile,
                evidence.reason,
                Self.timestamp(evidence.expiresAt),
            ]),
            occurredAt: evidence.attemptedAt,
            recordedAt: recordedAt,
            category: .quota,
            action: succeeded ? "reset_credit_consumed" : "reset_credit_attempted",
            title: succeeded ? "已自动使用 1 次额度重置" : "额度重置未完成",
            summary: succeeded
                ? "\(evidence.profile) 在额度耗尽后由\(producerLabel)自动执行重置。"
                : "\(evidence.profile) 的自动重置结果为 \(evidence.outcome)。",
            status: succeeded ? .success : .failure,
            importance: .critical,
            certainty: .confirmed,
            actor: producer,
            account: EventAccount(profile: evidence.profile),
            sourceChain: sourceChain,
            before: .object(["quota_state": .string(evidence.reason)]),
            after: .object(["reset_outcome": .string(evidence.outcome)]),
            evidence: [
                EventEvidence(kind: "user_defaults", label: "automatic-reset outcome"),
            ]
        )
    }

    private func lifecycleEvent(
        from record: LifecycleLedgerRecord,
        catalog: CodexMetadataCatalog,
        recordedAt: Date
    ) -> OperationEvent {
        let isTask = record.kind == .task
        let actionSuffix = record.event == "add" ? "added" : "updated"
        let sourceID = isTask ? "task-continuity-ledger" : "program-artifact-tracker"
        let sourceLabel = isTask ? "Task Continuity" : "Program Artifact Tracker"
        let statusText = record.item.status.map { " · 状态：\($0)" } ?? ""
        let failedStatuses = Set(["blocked", "error", "failed", "failure"])
        let failed = record.item.status.map { failedStatuses.contains($0.lowercased()) } ?? false
        let metadata = record.item.threadID.flatMap(catalog.thread(id:))
        return OperationEvent(
            schemaVersion: 1,
            id: StableEventID.make(parts: [
                "lifecycle",
                record.kind.rawValue,
                record.event,
                record.item.id,
                Self.timestamp(record.at),
            ]),
            occurredAt: record.at,
            recordedAt: recordedAt,
            category: .thread,
            action: "\(record.kind.rawValue)_\(actionSuffix)",
            title: isTask
                ? (record.event == "add" ? "已登记任务" : "任务记录已更新")
                : (record.event == "add" ? "已登记任务成果" : "任务成果已更新"),
            summary: record.item.title + statusText,
            status: failed ? .failure : .success,
            importance: failed ? .critical : .important,
            certainty: .confirmed,
            actor: EventActor(type: .hook, id: sourceID, label: sourceLabel),
            thread: record.item.threadID.map {
                EventThread(id: $0, title: metadata?.title, relation: .source)
            },
            project: EventProject(
                name: metadata?.projectName ?? record.item.projectName,
                path: metadata?.projectPath ?? record.item.projectPath
            ),
            evidence: [
                EventEvidence(
                    kind: isTask ? "task_ledger" : "work_ledger",
                    label: isTask ? "任务台账" : "成果台账"
                ),
            ]
        )
    }

    private static func timestamp(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }
}
