import CodexWorkbenchCore
import Foundation

func runCodexMetadataCatalogTests(_ runner: inout TestRunner) {
    let source = CodexThreadMetadata(
        id: "thread-source",
        rawTitle: "系统日志时间轴设计",
        projectPath: "/Users/example/program/tools",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 200),
        sourceThreadID: nil
    )
    let continued = CodexThreadMetadata(
        id: "thread-target",
        rawTitle: """
        <codex_delegation>
        <source_thread_id>thread-source</source_thread_id>
        <input># 接续：系统日志时间轴

        请基于 continuation pack 继续。
        </input>
        </codex_delegation>
        """,
        projectPath: "/Users/example/program/tools",
        createdAt: Date(timeIntervalSince1970: 300),
        updatedAt: Date(timeIntervalSince1970: 400),
        sourceThreadID: "thread-source"
    )
    let ordinary = CodexThreadMetadata(
        id: "thread-ordinary",
        rawTitle: "在现有项目中新建普通对话",
        projectPath: "/Users/example/program/tools",
        createdAt: Date(timeIntervalSince1970: 500),
        updatedAt: Date(timeIntervalSince1970: 600),
        sourceThreadID: nil
    )
    let newProject = CodexThreadMetadata(
        id: "thread-new-project",
        rawTitle: "设计菜谱库存系统",
        projectPath: "/Users/example/program/env",
        createdAt: Date(timeIntervalSince1970: 700),
        updatedAt: Date(timeIntervalSince1970: 800),
        sourceThreadID: nil
    )
    let catalog = CodexMetadataCatalog(records: [source, continued, ordinary, newProject])

    runner.expect(
        catalog.thread(id: "thread-target")?.title == "接续：系统日志时间轴",
        "Structured delegation titles should collapse to a useful conversation name"
    )
    runner.expect(
        catalog.thread(id: "thread-new-project")?.projectName == "env",
        "Project name should come from the normalized workspace path"
    )

    let baselineProjects = ProjectSpaceEventFactory().events(
        previousProjectPaths: nil,
        current: catalog,
        observedAt: Date(timeIntervalSince1970: 900)
    )
    runner.expect(baselineProjects.isEmpty, "The first project scan should establish a baseline without history spam")

    let projectEvents = ProjectSpaceEventFactory().events(
        previousProjectPaths: ["/Users/example/program/tools"],
        current: catalog,
        observedAt: Date(timeIntervalSince1970: 900)
    )
    runner.expect(projectEvents.count == 1, "Only a newly observed project path should create a project event")
    runner.expect(projectEvents.first?.action == "project_space_discovered", "New project event should use a stable action")
    runner.expect(projectEvents.first?.project?.name == "env", "New project event should retain project identity")
    runner.expect(projectEvents.first?.importance == .important, "New project spaces should be important")

    let baselineContinuations = ThreadContinuationEventFactory().events(
        previousThreadIDs: nil,
        current: catalog,
        observedAt: Date(timeIntervalSince1970: 900)
    )
    runner.expect(baselineContinuations.isEmpty, "The first thread scan should not replay historical continuations")

    let continuationEvents = ThreadContinuationEventFactory().events(
        previousThreadIDs: ["thread-source"],
        current: catalog,
        observedAt: Date(timeIntervalSince1970: 900)
    )
    runner.expect(continuationEvents.count == 1, "Only a new thread with a source thread should be logged")
    runner.expect(continuationEvents.first?.action == "thread_continued", "Continuation should use an explicit action")
    runner.expect(continuationEvents.first?.thread?.title == "接续：系统日志时间轴", "Continuation should expose target conversation title")
    runner.expect(
        continuationEvents.first?.summary.contains("系统日志时间轴设计") == true,
        "Continuation summary should expose the source conversation name"
    )

    let ordinaryOnly = CodexMetadataCatalog(records: [source, ordinary])
    let ordinaryEvents = ThreadContinuationEventFactory().events(
        previousThreadIDs: ["thread-source"],
        current: ordinaryOnly,
        observedAt: Date(timeIntervalSince1970: 900)
    )
    runner.expect(ordinaryEvents.isEmpty, "An ordinary new conversation in an existing project should not be logged")

    let legacyEvent = OperationEvent(
        schemaVersion: 1,
        id: "legacy-context-event",
        occurredAt: Date(timeIntervalSince1970: 100),
        recordedAt: Date(timeIntervalSince1970: 100),
        category: .context,
        action: "context_compacted",
        title: "上下文已压缩",
        summary: "已生成摘要卡片。",
        status: .success,
        importance: .critical,
        certainty: .confirmed,
        actor: EventActor(type: .hook, id: "precompact", label: "PreCompact Hook"),
        thread: EventThread(id: "thread-source", title: nil, relation: .triggeredBy)
    )
    let enriched = EventContextEnricher().enrich(events: [legacyEvent], catalog: catalog)
    runner.expect(enriched.first?.thread?.title == "系统日志时间轴设计", "Legacy events should resolve a readable conversation title")
    runner.expect(enriched.first?.project?.name == "tools", "Legacy events should resolve project identity from the thread catalog")
    runner.expect(enriched.first?.id == legacyEvent.id, "Enrichment must preserve stable event identity")
    runner.expect(enriched.first?.importance == .routine, "Legacy context compactions should adopt the routine display level")
}
