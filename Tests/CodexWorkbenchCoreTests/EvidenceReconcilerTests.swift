import CodexWorkbenchCore
import Foundation

func runEvidenceReconcilerTests(_ runner: inout TestRunner) {
    let keyParts = ["context-card", "019f6067-342c-7b22-a9fc-cd50ded08d86", "2026-07-14T21:35:15+08:00"]
    runner.expect(
        StableEventID.make(parts: keyParts) == StableEventID.make(parts: keyParts),
        "Stable ids should be deterministic across scans"
    )
    runner.expect(
        StableEventID.make(parts: keyParts) != StableEventID.make(parts: keyParts + ["different"]),
        "Different evidence should not collapse into one event"
    )

    let cardMarkdown = """
    # Codex 上下文摘要卡片

    - 生成时间: 2026-07-14T21:35:15+08:00
    - 触发事件: PreCompact (auto)
    - 会话 ID: `019f6067-342c-7b22-a9fc-cd50ded08d86`
    - 项目路径: `/Users/example/program/tools`
    - 卡片路径: `/Users/example/.codex/context-cards/card.md`

    ## 当前主题

    - # Files mentioned by the user: ## codex-clipboard-example.png

    ## 最近用户请求

    - `2026-07-16T05:20:00Z` **用户**: <recommended_plugins>这不是对话摘要内容</recommended_plugins>
    - `2026-07-16T05:27:51Z` **用户**: 等待外部条件时继续推进安全的并行工作，并持续监听恢复条件。
    - `2026-07-16T05:28:00Z` **用户**: # AGENTS.md instructions <INSTRUCTIONS>这不是对话摘要内容</INSTRUCTIONS>
    - `2026-07-16T05:28:01Z` **用户**: # Files mentioned by the user: ## codex-clipboard-example.png: /tmp/codex-clipboard-example.png

    ## 最近助手进展

    - `2026-07-16T05:28:39Z` **助手**: 已把 RC 观察与产品化前端拆成两条互不污染的执行轨道。
    - `2026-07-16T05:29:55Z` **助手**: 已建立隔离 worktree，接下来按 TDD 实现前端。
    """
    let card = ContextCardEvidence.parse(
        markdown: cardMarkdown,
        sourcePath: "/Users/example/.codex/context-cards/card.md"
    )
    runner.expect(card != nil, "A real context card header should parse")
    let attachmentRequestCard = ContextCardEvidence.parse(
        markdown: """
        - 生成时间: 2026-07-16T15:03:53+08:00
        - 触发事件: PreCompact (auto)
        - 会话 ID: `019f6067-342c-7b22-a9fc-cd50ded08d86`

        ## 最近用户请求

        - `2026-07-15T03:08:58.932Z` **用户**: # Files mentioned by the user: ## codex-clipboard-example.png: /tmp/codex-clipboard-example.png ## My request for Codex: 我看不出来具体调整在哪里，点开详情也没有介绍。
        """,
        sourcePath: "/Users/example/.codex/context-cards/attachment-request-card.md"
    )
    runner.expect(
        attachmentRequestCard?.summary.recentUserRequest == "我看不出来具体调整在哪里，点开详情也没有介绍。",
        "Attachment preambles should be removed while retaining an inline user request"
    )

    let preferences: [String: JSONValue] = [
        "automatic-reset.last-attempt.hd-master.rate_limit_reached.1784515205": .number(1_784_027_580.6553841),
        "automatic-reset.outcome.hd-master.rate_limit_reached.1784515205": .string("reset"),
        "automatic-reset.idempotency.hd-master.rate_limit_reached.1784515205": .string("secret-idempotency-key"),
        "automatic-reset.actor.hd-master.rate_limit_reached.1784515205": .string("codex-workbench"),
    ]
    let resets = AutomaticResetEvidence.parse(preferences: preferences)
    runner.expect(resets.count == 1, "A reset outcome and attempt should form one evidence item")
    runner.expect(resets.first?.profile == "hd-master", "Profile should parse from the reset key")
    runner.expect(resets.first?.outcome == "reset", "Reset outcome should parse")
    runner.expect(resets.first?.producer == "codex-workbench", "New reset evidence should retain its producer")

    let legacyReset = AutomaticResetEvidence.parse(preferences: [
        "automatic-reset.last-attempt.hd-master.primary.1784515205": .number(1_784_027_580),
        "automatic-reset.outcome.hd-master.primary.1784515205": .string("reset"),
    ])
    runner.expect(legacyReset.first?.producer == nil, "Legacy reset evidence should remain distinguishable")

    let taskLine = #"{"at":"2026-07-07T08:20:24Z","event":"update","task":{"id":"task_1","title":"线程关联项目工具","status":"done","project":{"name":"agent-tools","path":"/Users/example/program/tools/agent-tools"},"source":{"thread_id":"019f4613-1b48-7d00-a66f-788db5765f21","session_id":"019f4613-1b48-7d00-a66f-788db5765f21"}}}"#
    let taskRecord = LifecycleLedgerRecord.parse(line: taskLine, kind: .task)
    runner.expect(taskRecord?.item.title == "线程关联项目工具", "Task ledger title should parse")
    runner.expect(taskRecord?.item.threadID == "019f4613-1b48-7d00-a66f-788db5765f21", "Task thread should parse")

    let threadCatalog = CodexMetadataCatalog(records: [
        CodexThreadMetadata(
            id: "019f6067-342c-7b22-a9fc-cd50ded08d86",
            rawTitle: "Add 操作时间轴日志",
            projectPath: "/Users/example/program/tools",
            createdAt: Date(timeIntervalSince1970: 1_784_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_784_036_000),
            sourceThreadID: nil
        ),
    ])
    let snapshot = EvidenceSnapshot(
        contextCards: card.map { [$0] } ?? [],
        automaticResets: resets,
        lifecycleRecords: taskRecord.map { [$0] } ?? [],
        threadCatalog: threadCatalog
    )
    let recordedAt = Date(timeIntervalSince1970: 1_784_036_000)
    let events = EvidenceReconciler().events(from: snapshot, recordedAt: recordedAt)
    runner.expect(events.count == 3, "Context, reset, and task evidence should produce three events")

    let contextEvent = events.first { $0.action == "context_compacted" }
    runner.expect(contextEvent?.category == .context, "Context card should become a context event")
    runner.expect(contextEvent?.actor.type == .hook, "PreCompact should be attributed to a hook")
    runner.expect(contextEvent?.certainty == .confirmed, "Card metadata is confirmed evidence")
    runner.expect(contextEvent?.thread?.id == "019f6067-342c-7b22-a9fc-cd50ded08d86", "Context event should retain thread id")
    runner.expect(contextEvent?.thread?.title == "Add 操作时间轴日志", "Context event should resolve conversation title")
    runner.expect(contextEvent?.importance == .routine, "Context compaction should be a routine event")
    runner.expect(
        contextEvent?.summary.contains("等待外部条件时继续推进") == true,
        "Context list summaries should expose what the compacted context retained"
    )
    runner.expect(
        contextEvent?.changes?.contains {
            $0.label == "最近用户要求" && $0.summary.contains("安全的并行工作")
        } == true,
        "Context details should expose the latest meaningful user request"
    )
    runner.expect(
        contextEvent?.changes?.filter { $0.label == "压缩前进展" }.count == 2,
        "Context details should retain the two latest assistant progress summaries"
    )
    runner.expect(
        contextEvent?.changes?.contains { $0.summary.contains("recommended_plugins") } == false,
        "Injected plugin recommendations must not enter the context preview"
    )
    runner.expect(
        contextEvent?.changes?.contains { $0.summary.contains("codex-clipboard") } == false,
        "Attachment metadata must not replace the actual user request"
    )
    runner.expect(
        contextEvent?.changes?.contains { $0.summary.contains("AGENTS.md instructions") } == false,
        "Injected workspace instructions must not replace the actual user request"
    )
    let legacyContextEvent = OperationEvent(
        schemaVersion: 1,
        id: contextEvent?.id ?? "evt-context-legacy",
        occurredAt: card?.generatedAt ?? recordedAt,
        recordedAt: Date(timeIntervalSince1970: recordedAt.timeIntervalSince1970 - 1),
        category: .context,
        action: "context_compacted",
        title: "上下文已压缩",
        summary: "PreCompact 已生成中文摘要卡片，供压缩后继续使用。",
        status: .success,
        importance: .routine,
        certainty: .confirmed,
        actor: EventActor(type: .hook, id: "codex-context-summary-hook", label: "PreCompact Hook"),
        evidence: [EventEvidence(kind: "context_card", label: "上下文摘要卡片", path: card?.sourcePath)]
    )
    let contextRevision = ContextEventHistoryEnricher().revisions(
        events: [legacyContextEvent],
        cards: card.map { [$0] } ?? [],
        catalog: threadCatalog,
        recordedAt: recordedAt
    ).first
    runner.expect(
        contextRevision?.changes?.contains { $0.label == "最近用户要求" } == true,
        "Historic context events should be revised from their existing summary card"
    )
    runner.expect(
        ContextEventHistoryEnricher().revisions(
            events: contextRevision.map { [$0] } ?? [],
            cards: card.map { [$0] } ?? [],
            catalog: threadCatalog,
            recordedAt: recordedAt.addingTimeInterval(1)
        ).isEmpty,
        "An already enriched context event should not create another revision"
    )
    let attachmentMetadataEvent = OperationEvent(
        schemaVersion: legacyContextEvent.schemaVersion,
        id: legacyContextEvent.id,
        occurredAt: legacyContextEvent.occurredAt,
        recordedAt: recordedAt,
        category: legacyContextEvent.category,
        action: legacyContextEvent.action,
        title: legacyContextEvent.title,
        summary: "压缩后保留：# Files mentioned by the user: ## codex-clipboard-example.png",
        status: legacyContextEvent.status,
        importance: legacyContextEvent.importance,
        certainty: legacyContextEvent.certainty,
        actor: legacyContextEvent.actor,
        changes: [
            EventChange(label: "当前主题", summary: "# Files mentioned by the user: ## codex-clipboard-example.png"),
            EventChange(label: "最近用户要求", summary: "# Files mentioned by the user: ## codex-clipboard-example.png: /tmp/example.png"),
        ],
        evidence: legacyContextEvent.evidence
    )
    let cleanedContextRevision = ContextEventHistoryEnricher().revisions(
        events: [attachmentMetadataEvent],
        cards: card.map { [$0] } ?? [],
        catalog: threadCatalog,
        recordedAt: recordedAt.addingTimeInterval(2)
    ).first
    runner.expect(
        cleanedContextRevision?.changes?.contains {
            $0.label == "最近用户要求" && $0.summary.contains("安全的并行工作")
        } == true,
        "Historic context revisions polluted by attachment metadata should be upgraded again"
    )
    let progressOnlyEvent = OperationEvent(
        schemaVersion: attachmentMetadataEvent.schemaVersion,
        id: attachmentMetadataEvent.id,
        occurredAt: attachmentMetadataEvent.occurredAt,
        recordedAt: attachmentMetadataEvent.recordedAt,
        category: attachmentMetadataEvent.category,
        action: attachmentMetadataEvent.action,
        title: attachmentMetadataEvent.title,
        summary: "压缩后保留：已建立隔离 worktree，接下来按 TDD 实现前端。",
        status: attachmentMetadataEvent.status,
        importance: attachmentMetadataEvent.importance,
        certainty: attachmentMetadataEvent.certainty,
        actor: attachmentMetadataEvent.actor,
        changes: [EventChange(label: "压缩前进展", summary: "已建立隔离 worktree，接下来按 TDD 实现前端。")],
        evidence: attachmentMetadataEvent.evidence
    )
    runner.expect(
        ContextEventHistoryEnricher().revisions(
            events: [progressOnlyEvent],
            cards: card.map { [$0] } ?? [],
            catalog: threadCatalog,
            recordedAt: recordedAt.addingTimeInterval(3)
        ).first?.changes?.contains { $0.label == "最近用户要求" } == true,
        "A progress-only context revision should be upgraded when the card exposes a user request"
    )

    let resetEvent = events.first { $0.action == "reset_credit_consumed" }
    runner.expect(resetEvent?.category == .quota, "Reset outcome should become a quota event")
    runner.expect(resetEvent?.actor.id == "codex-workbench", "New reset should be attributed to the workbench")
    runner.expect(
        resetEvent?.sourceChain.map(\.id)
            == ["codex-workbench", "codex-profile-switcher", "automatic-reset"],
        "New reset evidence should preserve the workbench, account engine, and state machine chain"
    )
    runner.expect(resetEvent?.account?.profile == "hd-master", "Reset event should retain profile")
    runner.expect(resetEvent?.occurredAt.timeIntervalSince1970 == 1_784_027_580.6553841, "Reset should retain exact attempt time")

    let taskEvent = events.first { $0.action == "task_updated" }
    runner.expect(taskEvent?.thread?.relation == .source, "Lifecycle event should point to its source thread")
    runner.expect(taskEvent?.project?.name == "agent-tools", "Lifecycle event should retain project")

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-workbench-tests-\(UUID().uuidString)", isDirectory: true)
    let ledgerURL = temporaryDirectory.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let firstWrite = LedgerWriter().append(events: events, to: ledgerURL)
    let secondWrite = LedgerWriter().append(events: events, to: ledgerURL)
    runner.expect(firstWrite.appendedCount == 3, "First reconciliation should append every event")
    runner.expect(secondWrite.appendedCount == 0, "Second reconciliation should deduplicate stable ids")
    let persisted = LedgerRepository().load(from: ledgerURL)
    runner.expect(persisted.events.count == 3, "Persisted JSONL should remain decodable")
    let rawLedger = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
    runner.expect(rawLedger.contains("schema_version"), "Persisted ledger should use snake_case")
    runner.expect(rawLedger.contains("secret-idempotency-key") == false, "Idempotency values must never reach the ledger")
    runner.expect(rawLedger.contains("recommended_plugins") == false, "Injected context wrappers must not reach the ledger")

    let legacyResetEvent = EvidenceReconciler().events(
        from: EvidenceSnapshot(automaticResets: legacyReset),
        recordedAt: recordedAt
    ).first
    runner.expect(
        legacyResetEvent?.actor.id == "codex-profile-switcher",
        "Historical resets without a producer marker should keep their original attribution"
    )

    let fixtureRoot = temporaryDirectory.appendingPathComponent("evidence", isDirectory: true)
    let cardsDirectory = fixtureRoot.appendingPathComponent("context-cards", isDirectory: true)
    let taskLedgerURL = fixtureRoot.appendingPathComponent("task-ledger/tasks.jsonl")
    let workLedgerURL = fixtureRoot.appendingPathComponent("work-ledger/work.jsonl")
    try? FileManager.default.createDirectory(at: cardsDirectory, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: taskLedgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: workLedgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? cardMarkdown.write(
        to: cardsDirectory.appendingPathComponent("card.md"),
        atomically: true,
        encoding: .utf8
    )
    try? (taskLine + "\n").write(to: taskLedgerURL, atomically: true, encoding: .utf8)
    try? "".write(to: workLedgerURL, atomically: true, encoding: .utf8)
    let fixtureSnapshot = LocalEvidenceReader().read(
        paths: LocalEvidencePaths(
            contextCardsDirectory: cardsDirectory,
            taskLedgerURL: taskLedgerURL,
            workLedgerURL: workLedgerURL
        ),
        resetPreferences: preferences
    )
    runner.expect(fixtureSnapshot.contextCards.count == 1, "Reader should discover context card files")
    runner.expect(fixtureSnapshot.lifecycleRecords.count == 1, "Reader should discover lifecycle ledgers")
    runner.expect(fixtureSnapshot.automaticResets.count == 1, "Reader should accept an injectable reset source")
}
