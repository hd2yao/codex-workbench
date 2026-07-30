import CodexWorkbenchCore
import Foundation

func runObservationStateTests(_ runner: inout TestRunner) {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-observation-state-\(UUID().uuidString)", isDirectory: true)
    let stateURL = temporaryDirectory.appendingPathComponent("state.json")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let store = ObservationStateStore()
    runner.expect(store.load(from: stateURL) == nil, "A missing observation state should establish a first-run baseline")

    let baselineCatalog = CodexMetadataCatalog(records: [
        CodexThreadMetadata(
            id: "thread-source",
            rawTitle: "来源对话",
            projectPath: "/Users/example/program/tools",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            sourceThreadID: nil
        ),
    ])
    let ruleV1 = WorkflowFileFingerprint(
        path: "/Users/example/.codex/AGENTS.md",
        kind: .rule,
        label: "Codex 全局规则",
        modifiedAt: Date(timeIntervalSince1970: 900),
        fingerprint: "rule-v1"
    )
    let baselineEvidence = EvidenceSnapshot(
        threadCatalog: baselineCatalog,
        workflowFiles: [ruleV1]
    )
    let baselinePayload = makeAccountPayload(
        generatedAt: Date(timeIntervalSince1970: 1_000),
        remainingPercent: 2,
        resetsAt: Date(timeIntervalSince1970: 20_000),
        resetCredits: 3
    )
    let reconciler = ObservationStateReconciler()
    let baseline = reconciler.reconcile(
        previous: nil,
        evidence: baselineEvidence,
        accountPayload: baselinePayload,
        existingEvents: [],
        observedAt: Date(timeIntervalSince1970: 1_000)
    )
    runner.expect(baseline.events.isEmpty, "The first observation should only establish a baseline")

    runner.expect(store.save(baseline.state, to: stateURL), "Observation state should save atomically")
    runner.expect(store.load(from: stateURL) == baseline.state, "Persisted observation state should round-trip")

    let changedCatalog = CodexMetadataCatalog(records: baselineCatalog.records + [
        CodexThreadMetadata(
            id: "thread-target",
            rawTitle: "接续后的对话",
            projectPath: "/Users/example/program/env",
            createdAt: Date(timeIntervalSince1970: 1_050),
            updatedAt: Date(timeIntervalSince1970: 1_060),
            sourceThreadID: "thread-source"
        ),
    ])
    let ruleV2 = WorkflowFileFingerprint(
        path: ruleV1.path,
        kind: ruleV1.kind,
        label: ruleV1.label,
        modifiedAt: Date(timeIntervalSince1970: 1_050),
        fingerprint: "rule-v2"
    )
    let changed = reconciler.reconcile(
        previous: baseline.state,
        evidence: EvidenceSnapshot(threadCatalog: changedCatalog, workflowFiles: [ruleV2]),
        accountPayload: makeAccountPayload(
            generatedAt: Date(timeIntervalSince1970: 1_060),
            remainingPercent: 100,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            resetCredits: 4
        ),
        existingEvents: [],
        observedAt: Date(timeIntervalSince1970: 1_060)
    )
    let actions = Set(changed.events.map(\.action))
    runner.expect(actions.contains("project_space_discovered"), "A new project path should be reconciled")
    runner.expect(actions.contains("thread_continued"), "A structured continuation should be reconciled")
    runner.expect(actions.contains("workflow_rule_updated"), "A workflow fingerprint change should be reconciled")
    runner.expect(actions.contains("official_quota_restored"), "An out-of-window quota recovery should be reconciled")
    runner.expect(actions.contains("reset_credits_increased"), "A reset-credit grant should be reconciled")

    let unchanged = reconciler.reconcile(
        previous: changed.state,
        evidence: EvidenceSnapshot(threadCatalog: changedCatalog, workflowFiles: [ruleV2]),
        accountPayload: makeAccountPayload(
            generatedAt: Date(timeIntervalSince1970: 1_120),
            remainingPercent: 100,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            resetCredits: 4
        ),
        existingEvents: changed.events,
        observedAt: Date(timeIntervalSince1970: 1_120)
    )
    runner.expect(unchanged.events.isEmpty, "An unchanged combined state should not append duplicate events")

    let failedSource = reconciler.reconcile(
        previous: changed.state,
        evidence: EvidenceSnapshot(threadCatalog: changedCatalog, workflowFiles: [ruleV2]),
        accountPayload: nil,
        accountError: "backend timed out at /private/path",
        existingEvents: changed.events,
        observedAt: Date(timeIntervalSince1970: 1_180)
    )
    runner.expect(
        failedSource.events.contains { $0.action == "account_data_source_failed" && $0.status == .failure },
        "A new account data-source failure should be an important ledger event"
    )
    runner.expect(
        failedSource.state.accountErrorFingerprint?.contains("private") == false,
        "Observation state should retain only an error fingerprint, not raw details"
    )

    let recoveredSource = reconciler.reconcile(
        previous: failedSource.state,
        evidence: EvidenceSnapshot(threadCatalog: changedCatalog, workflowFiles: [ruleV2]),
        accountPayload: makeAccountPayload(
            generatedAt: Date(timeIntervalSince1970: 1_240),
            remainingPercent: 100,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            resetCredits: 4
        ),
        accountError: nil,
        existingEvents: failedSource.events,
        observedAt: Date(timeIntervalSince1970: 1_240)
    )
    runner.expect(
        recoveredSource.events.contains { $0.action == "account_data_source_recovered" && $0.status == .success },
        "Account data-source recovery should close the error transition"
    )
}

private func makeAccountPayload(
    generatedAt: Date,
    remainingPercent: Double,
    resetsAt: Date,
    resetCredits: Int
) -> AccountDashboardPayload {
    AccountDashboardPayload(
        generatedAt: generatedAt,
        activeProfile: "hd-master",
        desktopStatus: nil,
        profileRoles: nil,
        profiles: [
            AccountProfile(
                name: "hd-master",
                path: "/Users/example/.codex/profiles/hd-master",
                auth: "present",
                config: "present",
                rateLimits: AccountRateLimits(
                    primary: AccountQuotaWindow(
                        usedPercent: 100 - remainingPercent,
                        remainingPercent: remainingPercent,
                        windowMinutes: 300,
                        resetsAt: resetsAt.timeIntervalSince1970
                    ),
                    resetCredits: AccountResetCredits(availableCount: resetCredits)
                )
            ),
        ]
    )
}
