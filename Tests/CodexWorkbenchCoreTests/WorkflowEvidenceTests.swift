import CodexWorkbenchCore
import Foundation

func runWorkflowEvidenceTests(_ runner: inout TestRunner) {
    let now = Date(timeIntervalSince1970: 1_000)
    let ruleV1 = WorkflowFileFingerprint(
        path: "/Users/example/.codex/AGENTS.md",
        kind: .rule,
        label: "Codex 全局规则",
        modifiedAt: Date(timeIntervalSince1970: 900),
        fingerprint: "v1"
    )
    let ruleV2 = WorkflowFileFingerprint(
        path: ruleV1.path,
        kind: .rule,
        label: ruleV1.label,
        modifiedAt: now,
        fingerprint: "v2"
    )
    let skill = WorkflowFileFingerprint(
        path: "/Users/example/.codex/skills/example/SKILL.md",
        kind: .skill,
        label: "example",
        modifiedAt: now,
        fingerprint: "skill-v1"
    )

    runner.expect(
        WorkflowChangeEventFactory().events(previous: nil, current: [ruleV1], observedAt: now).isEmpty,
        "The first workflow scan should establish a baseline without replaying every installed skill"
    )
    let changed = WorkflowChangeEventFactory().events(
        previous: [ruleV1.path: ruleV1],
        current: [ruleV2, skill],
        observedAt: now
    )
    runner.expect(changed.count == 2, "A modified rule and added skill should each create an event")
    runner.expect(
        changed.contains { $0.action == "workflow_rule_updated" && $0.importance == .important },
        "Global rule updates should be important"
    )
    runner.expect(
        changed.contains { $0.action == "skill_added" && $0.actor.type == .skill },
        "New skills should be attributed to the skill layer"
    )

    runner.expect(
        WorkflowFileClassifier.classify(path: "/Users/example/.codex/auth.json") == nil,
        "Authentication files must never enter workflow monitoring"
    )
    runner.expect(
        WorkflowFileClassifier.classify(path: "/Users/example/.codex/hooks/__pycache__/hook.pyc") == nil,
        "Generated caches must not create workflow events"
    )
    runner.expect(
        WorkflowFileClassifier.classify(path: "/Users/example/.codex/hooks/context-summary-card.py")?.kind == .hook,
        "Hook source files should be tracked"
    )
    runner.expect(
        WorkflowFileClassifier.classify(path: "/Users/example/.codex/automations/codex/automation.toml")?.kind == .automation,
        "Automation definitions should be tracked"
    )
    runner.expect(
        WorkflowFileClassifier.classify(
            path: "/Users/example/program/codex-workflow-skills/frontend-design-workflow/SKILL.md"
        )?.kind == .skill,
        "The maintained workflow Skill source tree should be tracked"
    )
    runner.expect(
        WorkflowFileClassifier.classify(
            path: "/Users/example/program/skills/experimental-workflow/SKILL.md"
        )?.kind == .skill,
        "Project Skill source trees should use the same Skill classification"
    )

    let digest = DailyDigestEvidence(
        day: "2026-07-15",
        generatedAt: now,
        sourcePath: "/Users/example/.codex/task-ledger/digests/daily/2026-07-15.md"
    )
    let digestEvent = DailyDigestEventFactory().event(from: digest, recordedAt: now)
    runner.expect(digestEvent.action == "daily_digest_generated", "Daily digest should have an explicit action")
    runner.expect(digestEvent.importance == .important, "Daily digest should be more prominent than context compression")
    runner.expect(digestEvent.actor.type == .automation, "Daily digest should be attributed to automation")

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-workflow-semantic-\(UUID().uuidString)", isDirectory: true)
    let automationURL = temporaryDirectory
        .appendingPathComponent("automations/codex/automation.toml")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    try? FileManager.default.createDirectory(
        at: automationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let ruleURL = temporaryDirectory.appendingPathComponent("AGENTS.md")
    let oldRuleContent = """
    # Codex 全局规则

    ## 工作方式
    - 优先小步、可审查的改动。
    """
    let newRuleContent = """
    # Codex 全局规则

    ## 工作方式
    - 优先小步、可审查的改动。
    - 等待外部条件时登记监控、恢复动作和安全并行工作。
    """
    try? oldRuleContent.write(to: ruleURL, atomically: true, encoding: .utf8)
    let oldRuleSnapshot = WorkflowFileCollector().collect(roots: [ruleURL]).first
    try? newRuleContent.write(to: ruleURL, atomically: true, encoding: .utf8)
    let newRuleSnapshot = WorkflowFileCollector().collect(roots: [ruleURL]).first
    runner.expect(oldRuleSnapshot?.semanticSnapshot != nil, "Global rules should retain a safe semantic snapshot")
    if let oldRuleSnapshot, let newRuleSnapshot {
        let ruleEvent = WorkflowChangeEventFactory().events(
            previous: [oldRuleSnapshot.path: oldRuleSnapshot],
            current: [newRuleSnapshot],
            observedAt: now
        ).first
        runner.expect(
            ruleEvent?.changes?.contains {
                $0.label == "新增规则" && $0.summary.contains("登记监控、恢复动作")
            } == true,
            "Global rule updates should say which rule was added"
        )
        runner.expect(
            ruleEvent?.summary.contains("登记监控、恢复动作") == true,
            "Global rule list summaries should lead with the concrete rule change"
        )
    }

    let configURL = temporaryDirectory.appendingPathComponent("config.toml")
    try? "model = \"gpt-old\"\napi_key = \"private-config-marker\"\n".write(
        to: configURL,
        atomically: true,
        encoding: .utf8
    )
    let oldConfigSnapshot = WorkflowFileCollector().collect(roots: [configURL]).first
    try? "model = \"gpt-new\"\napi_key = \"private-config-marker\"\n".write(
        to: configURL,
        atomically: true,
        encoding: .utf8
    )
    let newConfigSnapshot = WorkflowFileCollector().collect(roots: [configURL]).first
    if let oldConfigSnapshot, let newConfigSnapshot {
        let configEvent = WorkflowChangeEventFactory().events(
            previous: [oldConfigSnapshot.path: oldConfigSnapshot],
            current: [newConfigSnapshot],
            observedAt: now
        ).first
        runner.expect(
            configEvent?.changes?.contains { $0.summary.contains("model") && $0.summary.contains("gpt-new") } == true,
            "Codex configuration updates should expose safe setting changes"
        )
        let encoded = configEvent.flatMap { try? LedgerWriter.encoder().encode($0) }
        let encodedText = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        runner.expect(
            encodedText.contains("private-config-marker") == false,
            "Sensitive configuration values must never enter semantic snapshots"
        )
    }

    let hooksConfigURL = temporaryDirectory.appendingPathComponent("hooks.json")
    let oldHooksConfig = """
    {
      "hooks": {
        "SessionStart": [{
          "matcher": "*",
          "hooks": [{"type": "command", "command": "/Users/example/.codex/hooks/task-continuity-hook.py"}]
        }]
      }
    }
    """
    let newHooksConfig = """
    {
      "hooks": {
        "SessionStart": [{
          "matcher": "*",
          "hooks": [
            {"type": "command", "command": "/Users/example/.codex/hooks/thread-health-guard-hook.py"},
            {"type": "command", "command": "/Users/example/.codex/hooks/task-continuity-hook.py"}
          ]
        }]
      }
    }
    """
    try? oldHooksConfig.write(to: hooksConfigURL, atomically: true, encoding: .utf8)
    let oldHooksSnapshot = WorkflowFileCollector().collect(roots: [hooksConfigURL]).first
    try? newHooksConfig.write(to: hooksConfigURL, atomically: true, encoding: .utf8)
    let newHooksSnapshot = WorkflowFileCollector().collect(roots: [hooksConfigURL]).first
    if let oldHooksSnapshot, let newHooksSnapshot {
        let hooksEvent = WorkflowChangeEventFactory().events(
            previous: [oldHooksSnapshot.path: oldHooksSnapshot],
            current: [newHooksSnapshot],
            observedAt: now
        ).first
        runner.expect(
            hooksEvent?.changes?.contains {
                $0.label == "新增设置"
                    && $0.summary.contains("SessionStart")
                    && $0.summary.contains("thread-health-guard-hook.py")
            } == true,
            "Hook JSON updates should name the trigger and newly registered command"
        )
    }

    let pluginURL = temporaryDirectory.appendingPathComponent("plugins/personal/example/plugin.json")
    try? FileManager.default.createDirectory(
        at: pluginURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? #"{"name":"Example","description":"管理本地任务"}"#.write(
        to: pluginURL,
        atomically: true,
        encoding: .utf8
    )
    let oldPluginSnapshot = WorkflowFileCollector().collect(roots: [pluginURL]).first
    try? #"{"name":"Example","description":"管理本地任务与续作监控"}"#.write(
        to: pluginURL,
        atomically: true,
        encoding: .utf8
    )
    let newPluginSnapshot = WorkflowFileCollector().collect(roots: [pluginURL]).first
    if let oldPluginSnapshot, let newPluginSnapshot {
        let pluginEvent = WorkflowChangeEventFactory().events(
            previous: [oldPluginSnapshot.path: oldPluginSnapshot],
            current: [newPluginSnapshot],
            observedAt: now
        ).first
        runner.expect(
            pluginEvent?.changes?.contains { $0.label == "用途调整" && $0.summary.contains("续作监控") } == true,
            "Plugin updates should explain their public-purpose change"
        )
    }

    let oldAutomation = """
    version = 1
    id = "codex"
    name = "Codex 每日任务摘要与仓库收尾"
    prompt = "DailyDigest\\ngh pr merge"
    status = "ACTIVE"
    rrule = "RRULE:FREQ=DAILY"
    target_thread_id = "thread-target"
    """
    try? oldAutomation.write(to: automationURL, atomically: true, encoding: .utf8)
    let oldSnapshot = WorkflowFileCollector().collect(roots: [automationURL]).first

    let newAutomation = """
    version = 1
    id = "codex"
    name = "Codex 每日任务摘要与仓库收尾"
    prompt = "DailyDigest\\nclear-activity\\nrepository-action-budget.py\\ngit worktree remove\\n--duration-seconds\\nprivate marker must never persist"
    status = "ACTIVE"
    rrule = "RRULE:FREQ=DAILY"
    target_thread_id = "thread-target"
    """
    try? newAutomation.write(to: automationURL, atomically: true, encoding: .utf8)
    let newSnapshot = WorkflowFileCollector().collect(roots: [automationURL]).first

    runner.expect(oldSnapshot?.semanticSnapshot != nil, "Automation collection should retain a safe semantic snapshot")
    runner.expect(
        newSnapshot?.semanticSnapshot?.capabilities.contains("动态仓库操作预算") == true,
        "Automation snapshots should derive stable capability labels"
    )
    if let oldSnapshot, let newSnapshot {
        let semanticEvents = WorkflowChangeEventFactory().events(
            previous: [oldSnapshot.path: oldSnapshot],
            current: [newSnapshot],
            observedAt: now
        )
        let event = semanticEvents.first
        runner.expect(
            event?.summary.contains("动态仓库操作预算") == true,
            "Automation list summaries should explain a concrete change"
        )
        runner.expect(
            event?.changes?.contains { $0.summary == "动态仓库操作预算" } == true,
            "Automation details should expose structured capability changes"
        )
        runner.expect(event?.scope == .globalWorkflow, "Automation changes should expose global workflow scope")
        runner.expect(
            event?.relatedThreads?.contains { $0.role == .deliveryTarget && $0.id == "thread-target" } == true,
            "Automation target threads should be distinct from modification-source threads"
        )
        let encoded = try? LedgerWriter.encoder().encode(event)
        let encodedText = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        runner.expect(
            encodedText.contains("private marker must never persist") == false,
            "Full automation prompts must never enter the operation ledger"
        )
    }

    let skillURL = temporaryDirectory
        .appendingPathComponent("skills/task-continuity/SKILL.md")
    try? FileManager.default.createDirectory(
        at: skillURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let oldSkillContent = """
    ---
    name: task-continuity
    description: 管理 Codex 待办、每日摘要和仓库收尾。
    ---

    # 任务连续性

    使用 task-ledger.py 与 repository-closure-audit.py。
    private skill body marker
    """
    try? oldSkillContent.write(to: skillURL, atomically: true, encoding: .utf8)
    let oldSkillSnapshot = WorkflowFileCollector().collect(roots: [skillURL]).first

    let newSkillContent = """
    ---
    name: task-continuity
    description: 管理 Codex 待办、每日摘要、周期任务健康和仓库收尾。
    ---

    # 任务连续性

    使用 task-ledger.py、repository-closure-audit.py 与 recurring-task-audit.py。
    private skill body marker
    """
    try? newSkillContent.write(to: skillURL, atomically: true, encoding: .utf8)
    let newSkillSnapshot = WorkflowFileCollector().collect(roots: [skillURL]).first

    runner.expect(
        oldSkillSnapshot?.semanticSnapshot?.purpose == "管理 Codex 待办、每日摘要和仓库收尾。",
        "Skill snapshots should retain the public purpose instead of only a fingerprint"
    )
    runner.expect(
        newSkillSnapshot?.semanticSnapshot?.capabilities.contains("周期任务健康审计") == true,
        "Skill snapshots should derive readable workflow capabilities"
    )
    if let oldSkillSnapshot, let newSkillSnapshot {
        let event = WorkflowChangeEventFactory().events(
            previous: [oldSkillSnapshot.path: oldSkillSnapshot],
            current: [newSkillSnapshot],
            observedAt: now
        ).first
        runner.expect(
            event?.changes?.contains { $0.label == "新增能力" && $0.summary == "周期任务健康审计" } == true,
            "Skill updates should explain newly added capabilities"
        )
        runner.expect(
            event?.summary.contains("周期任务健康审计") == true,
            "Skill list summaries should say what changed"
        )
        runner.expect(
            event?.summary.hasPrefix("task-continuity：周期任务健康审计") == true,
            "Skill list summaries should lead with the concrete capability instead of a long purpose paragraph"
        )
        let encoded = try? LedgerWriter.encoder().encode(event)
        let encodedText = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        runner.expect(
            encodedText.contains("private skill body marker") == false,
            "Skill bodies must never enter the operation ledger"
        )

        let legacy = WorkflowFileFingerprint(
            path: oldSkillSnapshot.path,
            kind: .skill,
            label: oldSkillSnapshot.label,
            modifiedAt: now,
            fingerprint: "legacy-skill",
            semanticSnapshot: nil
        )
        let fallback = WorkflowChangeEventFactory().events(
            previous: [legacy.path: legacy],
            current: [newSkillSnapshot],
            observedAt: now
        ).first
        runner.expect(
            fallback?.changes?.contains { $0.label == "更新后职责" } == true,
            "Legacy workflow updates should explain the confirmed current responsibility"
        )
        runner.expect(
            fallback?.changes?.contains { $0.label == "证据边界" } == true,
            "Legacy workflow updates must admit that the old semantic snapshot is missing"
        )
    }

    let hookURL = temporaryDirectory.appendingPathComponent("hooks/recurring-task-audit.py")
    try? FileManager.default.createDirectory(
        at: hookURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let hookContent = """
    \"\"\"审计项目声明的周期任务是否按计划产生新鲜成功证据。\"\"\"

    MANIFEST = ".codex/continuity.json"
    private hook body marker
    """
    try? hookContent.write(to: hookURL, atomically: true, encoding: .utf8)
    let hookSnapshot = WorkflowFileCollector().collect(roots: [hookURL]).first
    runner.expect(
        hookSnapshot?.semanticSnapshot?.purpose == "审计项目声明的周期任务是否按计划产生新鲜成功证据。",
        "Hook snapshots should retain a concise module responsibility"
    )
    runner.expect(
        hookSnapshot?.semanticSnapshot?.capabilities.contains("周期任务健康审计") == true,
        "Hook snapshots should expose readable capabilities"
    )
    if let hookSnapshot {
        let hookEvent = WorkflowChangeEventFactory().events(
            previous: [:],
            current: [hookSnapshot],
            observedAt: now
        ).first
        runner.expect(
            hookEvent?.changes?.contains { $0.label == "用途" } == true,
            "New hooks should explain their purpose"
        )
        runner.expect(
            hookEvent?.summary.contains("周期任务") == true,
            "New hook list summaries should describe what the hook does"
        )
        runner.expect(
            hookEvent?.summary.contains("。。") == false,
            "Workflow summaries should not duplicate terminal punctuation"
        )
    }

    let oldClosureSnapshot = WorkflowSemanticSnapshot.hook(content: """
    \"\"\"只读扫描本地仓库的收尾状态。\"\"\"
    """)
    let newClosureSnapshot = WorkflowSemanticSnapshot.hook(content: """
    \"\"\"只读扫描本地仓库的收尾状态。\"\"\"
    parser.add_argument("--refresh-remotes")
    patch_equivalent = True
    upstream_ahead = 1
    """)
    let oldClosure = WorkflowFileFingerprint(
        path: "/Users/example/.codex/hooks/repository-closure-audit.py",
        kind: .hook,
        label: "repository-closure-audit",
        modifiedAt: now,
        fingerprint: "closure-v1",
        semanticSnapshot: oldClosureSnapshot
    )
    let newClosure = WorkflowFileFingerprint(
        path: oldClosure.path,
        kind: .hook,
        label: oldClosure.label,
        modifiedAt: now,
        fingerprint: "closure-v2",
        semanticSnapshot: newClosureSnapshot
    )
    let closureEvent = WorkflowChangeEventFactory().events(
        previous: [oldClosure.path: oldClosure],
        current: [newClosure],
        observedAt: now
    ).first
    runner.expect(
        closureEvent?.changes?.contains { $0.summary == "远端状态刷新" } == true,
        "Repository closure updates should explain remote refresh support"
    )
    runner.expect(
        closureEvent?.changes?.contains { $0.summary == "提交等价性判定" } == true,
        "Repository closure updates should explain commit-equivalence checks"
    )
    runner.expect(
        closureEvent?.changes?.contains { $0.summary == "默认分支与上游分离判断" } == true,
        "Repository closure updates should explain the two comparison baselines"
    )
}
