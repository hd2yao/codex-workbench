import CodexWorkbenchCore
import Foundation

func runWorkflowEventEnrichmentTests(_ runner: inout TestRunner) {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-workflow-enrichment-\(UUID().uuidString)", isDirectory: true)
    let rolloutURL = temporaryDirectory.appendingPathComponent("rollout-source-thread.jsonl")
    let ledgerURL = temporaryDirectory.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    let boundedRolloutURL = temporaryDirectory.appendingPathComponent("bounded-rollout.jsonl")
    let privatePrefix = "private-prefix-marker-" + String(repeating: "x", count: 16_384)
    let irrelevantTail = "\n{\"payload\":{\"type\":\"message\",\"text\":\"irrelevant-tail-payload\"}}\n"
    let visibleSuffix = "{\"timestamp\":\"1970-01-01T00:03:20.000Z\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"*** Begin Patch visible-suffix\"}}\n"
    try? (privatePrefix + irrelevantTail + visibleSuffix).write(
        to: boundedRolloutURL,
        atomically: true,
        encoding: .utf8
    )
    let rolloutCache = WorkflowRolloutTextCache(maximumBytesPerFile: 4_096)
    let firstTail = rolloutCache.text(at: boundedRolloutURL.path)
    runner.expect(
        firstTail?.contains("visible-suffix") == true
            && firstTail?.contains("private-prefix-marker") == false
            && firstTail?.contains("irrelevant-tail-payload") == false,
        "Workflow evidence should retain only relevant lines from a bounded rollout tail"
    )
    try? "changed-after-first-read".write(
        to: boundedRolloutURL,
        atomically: true,
        encoding: .utf8
    )
    runner.expect(
        rolloutCache.text(at: boundedRolloutURL.path) == firstTail,
        "Workflow evidence should reuse one rollout read during a refresh"
    )

    let oldAutomation = """
    version = 1
    id = "codex"
    name = "Codex 每日任务摘要与仓库收尾"
    prompt = "DailyDigest\\ngh pr merge"
    status = "ACTIVE"
    rrule = "DTSTART:20260708T000000Z\\nRRULE:FREQ=DAILY"
    target_thread_id = "thread-target"
    """
    let updateInput = """
    const prompt = `DailyDigest
    clear-activity
    repository-action-budget.py
    git worktree remove
    --duration-seconds`;
    const result = await tools.codex_app__automation_update({
      id:"codex",
      mode:"update",
      prompt,
      rrule:"DTSTART:20260708T000000Z\\nRRULE:FREQ=DAILY",
      targetThreadId:"thread-target"
    });
    """
    let sessionLines = [
        sessionLine(
            timestamp: "1970-01-01T00:03:10.000Z",
            payload: [
                "type": "custom_tool_call_output",
                "output": [["type": "input_text", "text": oldAutomation]],
            ]
        ),
        sessionLine(
            timestamp: "1970-01-01T00:03:20.000Z",
            payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "input": updateInput,
            ]
        ),
    ]
    try? sessionLines.joined(separator: "\n").write(
        to: rolloutURL,
        atomically: true,
        encoding: .utf8
    )

    let sourceThread = CodexThreadMetadata(
        id: "thread-source",
        rawTitle: "修复每日摘要自动化",
        projectPath: "/Users/example/program/codex-workflow-skills",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 210),
        sourceThreadID: nil,
        rolloutPath: rolloutURL.path
    )
    let targetThread = CodexThreadMetadata(
        id: "thread-target",
        rawTitle: "Codex 摘要归档",
        projectPath: "/Users/example/Documents/Codex/codex-digest-archive",
        createdAt: Date(timeIntervalSince1970: 50),
        updatedAt: Date(timeIntervalSince1970: 190),
        sourceThreadID: nil,
        rolloutPath: nil
    )
    let catalog = CodexMetadataCatalog(records: [sourceThread, targetThread])
    let legacyEvent = OperationEvent(
        schemaVersion: 1,
        id: "evt-automation",
        occurredAt: Date(timeIntervalSince1970: 200),
        recordedAt: Date(timeIntervalSince1970: 205),
        category: .automation,
        action: "automation_updated",
        title: "Automation已更新",
        summary: "codex 的全局工作流定义已更新。",
        status: .success,
        importance: .important,
        certainty: .confirmed,
        actor: EventActor(type: .automation, id: "workflow-file-monitor", label: "codex"),
        before: .object(["fingerprint": .string("v1")]),
        after: .object(["fingerprint": .string("v2")]),
        evidence: [EventEvidence(
            kind: "file_fingerprint",
            label: "受控工作流文件指纹",
            path: "/Users/example/.codex/automations/codex/automation.toml"
        )]
    )

    let revisions = WorkflowEventHistoryEnricher().revisions(
        events: [legacyEvent],
        catalog: catalog,
        recordedAt: Date(timeIntervalSince1970: 220)
    )
    runner.expect(revisions.count == 1, "A legacy automation event with exact session evidence should be enriched once")
    let revision = revisions.first
    runner.expect(revision?.thread?.id == "thread-source", "Enrichment should retain the modification-source thread")
    runner.expect(revision?.project?.name == "codex-workflow-skills", "Source project should come from thread metadata")
    runner.expect(
        revision?.relatedThreads?.contains { $0.role == .modificationSource && $0.title == "修复每日摘要自动化" } == true,
        "Modification source should have an explicit role and title"
    )
    runner.expect(
        revision?.relatedThreads?.contains { $0.role == .deliveryTarget && $0.title == "Codex 摘要归档" } == true,
        "Delivery target should remain distinct and resolve its title"
    )
    runner.expect(
        revision?.changes?.contains { $0.summary == "前一日工作采集" } == true,
        "Historic enrichment should recover a safe human-readable change summary"
    )
    runner.expect(
        revision?.summary.contains("动态仓库操作预算") == true,
        "Historic list summaries should mention concrete changes"
    )
    runner.expect(
        revision?.changes?.contains { ["名称", "状态", "执行计划"].contains($0.label) } == false,
        "Fields omitted from a partial update call should inherit their previous values"
    )
    if let revision {
        runner.expect(
            WorkflowEventHistoryEnricher().revisions(
                events: [revision],
                catalog: catalog,
                recordedAt: Date(timeIntervalSince1970: 230)
            ).isEmpty,
            "An already-correct semantic revision should not be appended again"
        )
        let staleRevision = OperationEvent(
            schemaVersion: revision.schemaVersion,
            id: revision.id,
            occurredAt: revision.occurredAt,
            recordedAt: revision.recordedAt,
            category: revision.category,
            action: revision.action,
            title: revision.title,
            summary: "错误地把换行转义识别为执行计划变化。",
            status: revision.status,
            importance: revision.importance,
            certainty: revision.certainty,
            actor: revision.actor,
            thread: revision.thread,
            project: revision.project,
            account: revision.account,
            scope: revision.scope,
            changes: [
                EventChange(
                    label: "执行计划",
                    summary: "换行转义差异",
                    before: "DTSTART:20260708T000000Z\nRRULE:FREQ=DAILY",
                    after: "DTSTART:20260708T000000Z\\nRRULE:FREQ=DAILY"
                ),
            ],
            relatedThreads: revision.relatedThreads,
            sourceChain: revision.sourceChain,
            before: revision.before,
            after: revision.after,
            evidence: revision.evidence
        )
        let corrected = WorkflowEventHistoryEnricher().revisions(
            events: [staleRevision],
            catalog: catalog,
            recordedAt: Date(timeIntervalSince1970: 230)
        )
        runner.expect(corrected.count == 1, "A stale semantic revision should receive one corrected revision")
        runner.expect(
            corrected.first?.changes?.contains { $0.label == "执行计划" } == false,
            "The corrected revision should remove the false schedule change"
        )
    }

    let wordingOnlyRolloutURL = temporaryDirectory.appendingPathComponent("rollout-wording-only.jsonl")
    let wordingOnlyUpdate = """
    const prompt = `DailyDigest
    gh pr merge
    wording changed without a recognized capability change`;
    const result = await tools.codex_app__automation_update({
      id:"codex",
      mode:"update",
      prompt,
      targetThreadId:"thread-target"
    });
    """
    try? [
        sessionLine(
            timestamp: "1970-01-01T00:03:10.000Z",
            payload: [
                "type": "custom_tool_call_output",
                "output": [["type": "input_text", "text": oldAutomation]],
            ]
        ),
        sessionLine(
            timestamp: "1970-01-01T00:03:20.000Z",
            payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "input": wordingOnlyUpdate,
            ]
        ),
    ].joined(separator: "\n").write(to: wordingOnlyRolloutURL, atomically: true, encoding: .utf8)
    let wordingOnlyThread = CodexThreadMetadata(
        id: "thread-wording-only",
        rawTitle: "调整自动化措辞",
        projectPath: "/Users/example/program/codex-workflow-skills",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 210),
        sourceThreadID: nil,
        rolloutPath: wordingOnlyRolloutURL.path
    )
    let explainedAutomationEvent = OperationEvent(
        schemaVersion: legacyEvent.schemaVersion,
        id: "evt-automation-no-downgrade",
        occurredAt: legacyEvent.occurredAt,
        recordedAt: legacyEvent.recordedAt,
        category: legacyEvent.category,
        action: legacyEvent.action,
        title: legacyEvent.title,
        summary: "codex：前一日工作采集；仓库收尾。",
        status: legacyEvent.status,
        importance: legacyEvent.importance,
        certainty: legacyEvent.certainty,
        actor: legacyEvent.actor,
        scope: .globalWorkflow,
        changes: [
            EventChange(label: "更新后包含", summary: "前一日工作采集", after: "前一日工作采集"),
            EventChange(label: "更新后包含", summary: "仓库收尾", after: "仓库收尾"),
            EventChange(label: "证据边界", summary: "未保留更新前语义快照"),
        ],
        before: legacyEvent.before,
        after: legacyEvent.after,
        evidence: legacyEvent.evidence + [EventEvidence(
            kind: "current_workflow_snapshot",
            label: "当前工作流安全语义快照",
            path: "/Users/example/.codex/automations/codex/automation.toml"
        )]
    )
    runner.expect(
        WorkflowEventHistoryEnricher().revisions(
            events: [explainedAutomationEvent],
            catalog: CodexMetadataCatalog(records: [wordingOnlyThread, targetThread]),
            recordedAt: Date(timeIntervalSince1970: 220)
        ).isEmpty,
        "A concrete current-snapshot explanation must not be downgraded to a generic Automation revision"
    )

    _ = LedgerWriter().append(events: [legacyEvent], to: ledgerURL)
    let firstRevision = LedgerWriter().appendRevisions(events: revisions, to: ledgerURL)
    let repeatedRevision = LedgerWriter().appendRevisions(events: revisions, to: ledgerURL)
    runner.expect(firstRevision.appendedCount == 1, "An enhanced revision should append without destroying history")
    runner.expect(repeatedRevision.appendedCount == 0, "Appending the same enhanced revision should be idempotent")
    let loaded = LedgerRepository().load(from: ledgerURL)
    runner.expect(loaded.events.count == 1, "Repository should collapse base and enhanced rows by stable id")
    runner.expect(loaded.events.first?.changes?.isEmpty == false, "The latest enhanced revision should win")

    let ambiguousRolloutURL = temporaryDirectory.appendingPathComponent("rollout-ambiguous.jsonl")
    try? sessionLines.joined(separator: "\n").write(
        to: ambiguousRolloutURL,
        atomically: true,
        encoding: .utf8
    )
    let ambiguousThread = CodexThreadMetadata(
        id: "thread-ambiguous",
        rawTitle: "另一个候选对话",
        projectPath: "/Users/example/program/tools",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 210),
        sourceThreadID: nil,
        rolloutPath: ambiguousRolloutURL.path
    )
    let ambiguousCatalog = CodexMetadataCatalog(records: [sourceThread, ambiguousThread, targetThread])
    runner.expect(
        WorkflowEventHistoryEnricher().revisions(
            events: [legacyEvent],
            catalog: ambiguousCatalog,
            recordedAt: Date(timeIntervalSince1970: 220)
        ).isEmpty,
        "Multiple exact session matches must degrade instead of inventing a source conversation"
    )

    let variableRolloutURL = temporaryDirectory.appendingPathComponent("rollout-variable-update.jsonl")
    let variableInput = """
    const cfgResult = await tools.exec_command({
      cmd:"read /Users/example/.codex/automations/codex/automation.toml"
    });
    const cfg = JSON.parse(cfgResult.output);
    const updatedPrompt = cfg.prompt.replace("list_threads(limit=100)", "list_threads(limit=50)");
    const result = await tools.codex_app__automation_update({
      id:cfg.id,
      mode:"update",
      prompt:updatedPrompt,
      status:cfg.status
    });
    """
    let variableLines = [sessionLine(
        timestamp: "1970-01-01T00:03:20.000Z",
        payload: [
            "type": "custom_tool_call",
            "name": "exec",
            "input": variableInput,
        ]
    )]
    try? variableLines.joined(separator: "\n").write(
        to: variableRolloutURL,
        atomically: true,
        encoding: .utf8
    )
    let variableThread = CodexThreadMetadata(
        id: "thread-variable-source",
        rawTitle: "缩小每日任务扫描范围",
        projectPath: "/Users/example/program/codex-workflow-skills",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 210),
        sourceThreadID: nil,
        rolloutPath: variableRolloutURL.path
    )
    let variableRevision = WorkflowEventHistoryEnricher().revisions(
        events: [legacyEvent],
        catalog: CodexMetadataCatalog(records: [variableThread]),
        recordedAt: Date(timeIntervalSince1970: 220)
    ).first
    runner.expect(
        variableRevision?.thread?.id == "thread-variable-source",
        "Variable-style automation updates should still resolve their source thread"
    )
    runner.expect(
        variableRevision?.changes?.contains {
            $0.label == "任务扫描范围"
                && $0.before == "100"
                && $0.after == "50"
        } == true,
        "Replacement-style automation updates should explain the concrete old and new values"
    )

    let reorderedInput = """
    const cfgResult = await tools.exec_command({
      cmd:"read /Users/example/.codex/automations/codex/automation.toml"
    });
    const cfg = JSON.parse(cfgResult.output);
    const oldBlock = `先运行 clear-activity 清理旧记录，再使用 list_threads(limit=50) 读取候选任务。`;
    const newBlock = `先使用 list_threads(limit=50) 读取候选任务；读取成功后再运行 clear-activity 重建，读取失败时保留现有记录。`;
    const updatedPrompt = cfg.prompt.replace(oldBlock, newBlock);
    const result = await tools.codex_app__automation_update({
      id:cfg.id,
      mode:"update",
      prompt:updatedPrompt,
      status:cfg.status
    });
    """
    let reorderedLine = sessionLine(
        timestamp: "1970-01-01T00:04:00.000Z",
        payload: [
            "type": "custom_tool_call",
            "name": "exec",
            "input": reorderedInput,
        ]
    )
    try? (variableLines + [reorderedLine]).joined(separator: "\n").write(
        to: variableRolloutURL,
        atomically: true,
        encoding: .utf8
    )
    let reorderedEvidence = AutomationSessionEvidenceCollector().evidence(
        automationID: "codex",
        occurredAt: Date(timeIntervalSince1970: 240),
        catalog: CodexMetadataCatalog(records: [variableThread])
    ).first
    runner.expect(
        reorderedEvidence?.directChanges.contains {
            $0.label == "活动记录重建顺序"
                && $0.summary.contains("读取失败时保留")
        } == true,
        "Named replacement blocks should explain the safer read-before-clear order"
    )

    let skillURL = temporaryDirectory.appendingPathComponent("skills/task-continuity/SKILL.md")
    try? FileManager.default.createDirectory(
        at: skillURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? """
    ---
    name: task-continuity
    description: 管理每日任务摘要并审计周期任务运行状态。
    ---
    recurring-task-audit.py
    """.write(to: skillURL, atomically: true, encoding: .utf8)
    let currentSkill = WorkflowFileCollector().collect(roots: [skillURL]).first
    let legacySkill = OperationEvent(
        schemaVersion: 1,
        id: "evt-skill-legacy",
        occurredAt: Date(timeIntervalSince1970: 200),
        recordedAt: Date(timeIntervalSince1970: 205),
        category: .skill,
        action: "skill_updated",
        title: "Skill已更新",
        summary: "task-continuity 的全局工作流定义已更新。",
        status: .success,
        importance: .important,
        certainty: .confirmed,
        actor: EventActor(type: .skill, id: "workflow-file-monitor", label: "task-continuity"),
        before: .object(["fingerprint": .string("skill-v1")]),
        after: .object(["fingerprint": .string("skill-v2")]),
        evidence: [EventEvidence(kind: "file_fingerprint", label: "受控工作流文件指纹", path: skillURL.path)]
    )
    if let currentSkill {
        let fallbackRevision = WorkflowEventHistoryEnricher().revisions(
            events: [legacySkill],
            catalog: CodexMetadataCatalog(),
            currentWorkflowFiles: [currentSkill],
            recordedAt: Date(timeIntervalSince1970: 220)
        ).first
        runner.expect(
            fallbackRevision?.changes?.contains { $0.label == "更新后职责" } == true,
            "Existing generic Skill events should be backfilled from the current safe snapshot"
        )
        runner.expect(
            fallbackRevision?.changes?.contains { $0.label == "证据边界" } == true,
            "Historic Skill backfill should not pretend the current snapshot is an exact diff"
        )
    }

    let hookURL = temporaryDirectory.appendingPathComponent("hooks/recurring-task-audit.py")
    try? FileManager.default.createDirectory(
        at: hookURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? """
    \"\"\"审计项目声明的周期任务是否按计划产生新鲜成功证据。\"\"\"
    MANIFEST = ".codex/continuity.json"
    """.write(to: hookURL, atomically: true, encoding: .utf8)
    let currentHook = WorkflowFileCollector().collect(roots: [hookURL]).first
    let legacyHookAdded = OperationEvent(
        schemaVersion: 1,
        id: "evt-hook-added-legacy",
        occurredAt: Date(timeIntervalSince1970: 200),
        recordedAt: Date(timeIntervalSince1970: 205),
        category: .hook,
        action: "hook_added",
        title: "Hook已新增",
        summary: "recurring-task-audit 的全局工作流定义已新增。",
        status: .success,
        importance: .important,
        certainty: .confirmed,
        actor: EventActor(type: .hook, id: "workflow-file-monitor", label: "recurring-task-audit"),
        after: .object(["fingerprint": .string("hook-v1")]),
        evidence: [EventEvidence(kind: "file_fingerprint", label: "受控工作流文件指纹", path: hookURL.path)]
    )
    if let currentHook {
        let addedRevision = WorkflowEventHistoryEnricher().revisions(
            events: [legacyHookAdded],
            catalog: CodexMetadataCatalog(),
            currentWorkflowFiles: [currentHook],
            recordedAt: Date(timeIntervalSince1970: 220)
        ).first
        runner.expect(
            addedRevision?.changes?.contains { $0.label == "用途" } == true,
            "Historic added Hook events should explain what the new hook does"
        )
        runner.expect(
            addedRevision?.changes?.contains { $0.label == "证据边界" } == false,
            "A confirmed added file should not be described as a missing-old-snapshot update"
        )
    }

    let repositoryURL = temporaryDirectory.appendingPathComponent("workflow-source-repository", isDirectory: true)
    let sourceSkillURL = repositoryURL.appendingPathComponent("codex-task-continuity/SKILL.md")
    let installedSkillURL = temporaryDirectory
        .appendingPathComponent("installed/skills/codex-task-continuity/SKILL.md")
    try? FileManager.default.createDirectory(
        at: sourceSkillURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? FileManager.default.createDirectory(
        at: installedSkillURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let gitOldSkill = """
    ---
    name: codex-task-continuity
    description: 管理每日摘要和仓库收尾。
    ---
    repository-closure-audit.py
    """
    let gitNewSkill = """
    ---
    name: codex-task-continuity
    description: 管理每日摘要、周期任务健康和仓库收尾。
    ---
    repository-closure-audit.py
    recurring-task-audit.py
    """
    try? gitOldSkill.write(to: sourceSkillURL, atomically: true, encoding: .utf8)
    let didPrepareRepository = runGit(["init", "-q"], in: repositoryURL)
        && runGit(["config", "user.name", "Codex Workbench Tests"], in: repositoryURL)
        && runGit(["config", "user.email", "codex-workbench@example.invalid"], in: repositoryURL)
        && runGit(["add", "codex-task-continuity/SKILL.md"], in: repositoryURL)
        && runGit(["commit", "-q", "-m", "old skill"], in: repositoryURL)
    try? gitNewSkill.write(to: sourceSkillURL, atomically: true, encoding: .utf8)
    let didCommitUpdate = runGit(["add", "codex-task-continuity/SKILL.md"], in: repositoryURL)
        && runGit(["commit", "-q", "-m", "add recurring audit"], in: repositoryURL)
    try? gitNewSkill.write(to: installedSkillURL, atomically: true, encoding: .utf8)
    let installedGitSkill = WorkflowFileCollector().collect(roots: [installedSkillURL]).first
    runner.expect(didPrepareRepository && didCommitUpdate, "Git history fixture should be available")
    if let installedGitSkill {
        let gitLegacyEvent = OperationEvent(
            schemaVersion: 1,
            id: "evt-skill-git-history",
            occurredAt: Date(timeIntervalSince1970: 200),
            recordedAt: Date(timeIntervalSince1970: 205),
            category: .skill,
            action: "skill_updated",
            title: "Skill已更新",
            summary: "codex-task-continuity 的全局工作流定义已更新。",
            status: .success,
            importance: .important,
            certainty: .confirmed,
            actor: EventActor(type: .skill, id: "workflow-file-monitor", label: "codex-task-continuity"),
            before: .object(["fingerprint": .string("old-skill-fingerprint")]),
            after: .object(["fingerprint": .string(installedGitSkill.fingerprint)]),
            evidence: [EventEvidence(
                kind: "file_fingerprint",
                label: "受控工作流文件指纹",
                path: installedSkillURL.path
            )]
        )
        let gitRevision = WorkflowEventHistoryEnricher().revisions(
            events: [gitLegacyEvent],
            catalog: CodexMetadataCatalog(),
            currentWorkflowFiles: [installedGitSkill],
            workflowSourceRoots: [repositoryURL],
            recordedAt: Date(timeIntervalSince1970: 220)
        ).first
        runner.expect(
            gitRevision?.changes?.contains {
                $0.label == "新增能力" && $0.summary == "周期任务健康审计"
            } == true,
            "Matching Git before/after blobs should recover the exact Skill capability change"
        )
        runner.expect(
            gitRevision?.changes?.contains { $0.label == "证据边界" } == false,
            "Exact Git history should replace the current-snapshot fallback"
        )
        runner.expect(
            gitRevision?.evidence.contains { $0.kind == "git_workflow_history" } == true,
            "Exact Git enrichment should identify its evidence source"
        )
    }

    let ruleRolloutURL = temporaryDirectory.appendingPathComponent("rollout-rule-source.jsonl")
    let rulePatchInput = """
    const patch = "*** Begin Patch\\n*** Update File: /Users/example/.codex/AGENTS.md\\n@@\\n - 如果任务明显匹配已有 skill，先读取并使用相关 skill。\\n+- 当目标因定时任务、CI、审批或其他外部条件等待时，使用 `codex-task-continuity` 登记等待条件、监控、恢复动作和安全并行工作；有可推进轨道时不要把整个目标标记为 `blocked`，确定性条件默认绑定原线程自动续作。\\n*** End Patch";
    text(await tools.apply_patch(patch));
    """
    try? [
        sessionLine(
            timestamp: "1970-01-01T00:03:50.000Z",
            payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "input": rulePatchInput,
            ]
        ),
        sessionLine(
            timestamp: "1970-01-01T00:03:51.000Z",
            payload: [
                "type": "custom_tool_call",
                "name": "exec",
                "input": rulePatchInput,
            ]
        ),
    ].joined(separator: "\n").write(to: ruleRolloutURL, atomically: true, encoding: .utf8)
    let ruleSourceThread = CodexThreadMetadata(
        id: "thread-rule-source",
        rawTitle: "完善等待任务续作规则",
        projectPath: "/Users/example/program/codex-workflow-skills",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 260),
        sourceThreadID: nil,
        rolloutPath: ruleRolloutURL.path
    )
    let legacyRuleEvent = OperationEvent(
        schemaVersion: 1,
        id: "evt-rule-patch-history",
        occurredAt: Date(timeIntervalSince1970: 240),
        recordedAt: Date(timeIntervalSince1970: 245),
        category: .system,
        action: "workflow_rule_updated",
        title: "全局规则已更新",
        summary: "Codex 全局规则：全局规则内容已调整。",
        status: .success,
        importance: .important,
        certainty: .confirmed,
        actor: EventActor(type: .system, id: "workflow-file-monitor", label: "Codex 全局规则"),
        scope: .globalWorkflow,
        changes: [EventChange(label: "工作流定义", summary: "全局规则内容已调整")],
        before: .object(["fingerprint": .string("rule-old")]),
        after: .object(["fingerprint": .string("rule-new")]),
        evidence: [EventEvidence(
            kind: "file_fingerprint",
            label: "受控工作流文件指纹",
            path: "/Users/example/.codex/AGENTS.md"
        )]
    )
    let rulePatchRevision = WorkflowEventHistoryEnricher().revisions(
        events: [legacyRuleEvent],
        catalog: CodexMetadataCatalog(records: [ruleSourceThread]),
        currentWorkflowFiles: [],
        workflowSourceRoots: [],
        recordedAt: Date(timeIntervalSince1970: 270)
    ).first
    runner.expect(
        rulePatchRevision?.changes?.contains {
            $0.label == "新增规则"
                && $0.summary.contains("登记等待条件")
                && $0.summary.contains("恢复动作")
        } == true,
        "Structured patch evidence should recover the exact added global rule"
    )
    runner.expect(
        rulePatchRevision?.thread?.id == "thread-rule-source",
        "Structured patch evidence should identify the modification-source thread"
    )
    runner.expect(
        rulePatchRevision?.evidence.contains { $0.kind == "structured_workflow_patch" } == true,
        "Global rule enrichment should identify its structured patch evidence"
    )
    if let rulePatchRevision {
        let encoded = try? LedgerWriter.encoder().encode(rulePatchRevision)
        let encodedText = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        runner.expect(
            encodedText.contains("*** Begin Patch") == false,
            "The full structured patch must never enter the operation ledger"
        )
    }

    let capabilityOnlyRuleEvent = OperationEvent(
        schemaVersion: legacyRuleEvent.schemaVersion,
        id: legacyRuleEvent.id,
        occurredAt: legacyRuleEvent.occurredAt,
        recordedAt: Date(timeIntervalSince1970: 260),
        category: legacyRuleEvent.category,
        action: legacyRuleEvent.action,
        title: legacyRuleEvent.title,
        summary: "Codex 全局规则：安全并行轨道；自动恢复动作。",
        status: legacyRuleEvent.status,
        importance: legacyRuleEvent.importance,
        certainty: legacyRuleEvent.certainty,
        actor: legacyRuleEvent.actor,
        scope: legacyRuleEvent.scope,
        changes: [
            EventChange(label: "新增能力", summary: "安全并行轨道", after: "安全并行轨道"),
            EventChange(label: "新增能力", summary: "自动恢复动作", after: "自动恢复动作"),
        ],
        before: legacyRuleEvent.before,
        after: legacyRuleEvent.after,
        evidence: legacyRuleEvent.evidence + [EventEvidence(
            kind: "structured_workflow_patch",
            label: "结构化工作流修改调用",
            path: ruleRolloutURL.path
        )]
    )
    let correctedCapabilityOnlyRule = WorkflowEventHistoryEnricher().revisions(
        events: [capabilityOnlyRuleEvent],
        catalog: CodexMetadataCatalog(records: [ruleSourceThread]),
        currentWorkflowFiles: [],
        workflowSourceRoots: [],
        recordedAt: Date(timeIntervalSince1970: 280)
    ).first
    runner.expect(
        correctedCapabilityOnlyRule?.changes?.contains { $0.label == "新增规则" } == true,
        "A capability-only rule revision should be upgraded to the concrete added directive"
    )

    let hooksRolloutURL = temporaryDirectory.appendingPathComponent("rollout-hooks-source.jsonl")
    let hooksPatchInput = """
    const patch = "*** Begin Patch\\n*** Update File: /Users/example/.codex/hooks.json\\n@@\\n           \\"hooks\\": [\\n+            {\\n+              \\"type\\": \\"command\\",\\n+              \\"command\\": \\"/Users/example/.codex/hooks/thread-health-guard-hook.py\\"\\n+            },\\n             {\\n*** End Patch";
    text(await tools.apply_patch(patch));
    """
    try? sessionLine(
        timestamp: "1970-01-01T00:03:55.000Z",
        payload: [
            "type": "custom_tool_call",
            "name": "exec",
            "input": hooksPatchInput,
        ]
    ).write(to: hooksRolloutURL, atomically: true, encoding: .utf8)
    let hooksSourceThread = CodexThreadMetadata(
        id: "thread-hooks-source",
        rawTitle: "接入线程健康提醒 Hook",
        projectPath: "/Users/example/program/codex-workflow-skills",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 260),
        sourceThreadID: nil,
        rolloutPath: hooksRolloutURL.path
    )
    let legacyHooksEvent = OperationEvent(
        schemaVersion: 1,
        id: "evt-hooks-patch-history",
        occurredAt: Date(timeIntervalSince1970: 240),
        recordedAt: Date(timeIntervalSince1970: 245),
        category: .system,
        action: "workflow_config_updated",
        title: "Codex 配置已更新",
        summary: "hooks.json：Codex 配置内容已调整。",
        status: .success,
        importance: .important,
        certainty: .confirmed,
        actor: EventActor(type: .system, id: "workflow-file-monitor", label: "hooks.json"),
        scope: .globalWorkflow,
        changes: [EventChange(label: "工作流定义", summary: "Codex 配置内容已调整")],
        before: .object(["fingerprint": .string("hooks-old")]),
        after: .object(["fingerprint": .string("hooks-new")]),
        evidence: [EventEvidence(
            kind: "file_fingerprint",
            label: "受控工作流文件指纹",
            path: "/Users/example/.codex/hooks.json"
        )]
    )
    let hooksPatchRevision = WorkflowEventHistoryEnricher().revisions(
        events: [legacyHooksEvent],
        catalog: CodexMetadataCatalog(records: [hooksSourceThread]),
        currentWorkflowFiles: [],
        workflowSourceRoots: [],
        recordedAt: Date(timeIntervalSince1970: 280)
    ).first
    runner.expect(
        hooksPatchRevision?.changes?.contains {
            $0.summary.contains("thread-health-guard-hook.py")
        } == true,
        "Hook JSON patch history should name the newly registered command"
    )
}

private func runGit(_ arguments: [String], in directory: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func sessionLine(timestamp: String, payload: [String: Any]) -> String {
    let object: [String: Any] = [
        "timestamp": timestamp,
        "type": "response_item",
        "payload": payload,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
