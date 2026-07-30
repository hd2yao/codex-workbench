import CodexWorkbenchCore
import Foundation

func runLedgerRepositoryTests(_ runner: inout TestRunner) {
    let confirmedEvent = #"{"schema_version":1,"id":"evt-reset","occurred_at":"2026-07-14T19:13:00+08:00","recorded_at":"2026-07-14T19:13:01+08:00","category":"quota","action":"reset_credit_consumed","title":"已使用 1 次额度重置","summary":"hd-master 的可用额度恢复为 100%","status":"success","importance":"critical","certainty":"confirmed","actor":{"type":"app","id":"codex-profile-switcher","label":"Profile Switcher"},"thread":{"id":"6a5620e6-c00c-83ec-869b-19d5f8de738b","title":"系统日志时间轴设计","relation":"active_at_time"},"account":{"profile":"hd-master"},"source_chain":[{"type":"app","id":"codex-profile-switcher","label":"Profile Switcher"},{"type":"system","id":"automatic-reset","label":"自动重置状态机"}],"before":{"remaining_percent":0,"reset_credits":2},"after":{"remaining_percent":100,"reset_credits":1},"evidence":[{"kind":"user_defaults","label":"automatic-reset outcome"}]}"#

    let decoded = LedgerRepository().load(data: Data((confirmedEvent + "\n").utf8))
    runner.expect(decoded.warnings.isEmpty, "A valid event should not produce warnings")
    runner.expect(decoded.events.count == 1, "A valid JSONL row should decode")
    if let event = decoded.events.first {
        runner.expect(event.id == "evt-reset", "Event id should decode")
        runner.expect(event.category == .quota, "Category should decode")
        runner.expect(event.status == .success, "Status should decode")
        runner.expect(event.importance == .critical, "Importance should decode")
        runner.expect(event.certainty == .confirmed, "Certainty should decode")
        runner.expect(event.actor.type == .app, "Actor type should decode")
        runner.expect(event.thread?.relation == .activeAtTime, "Thread relation should decode")
        runner.expect(event.account?.profile == "hd-master", "Account profile should decode")
        runner.expect(event.sourceChain.count == 2, "Source chain should decode")
        runner.expect(event.before != nil && event.after != nil, "Before/after should decode")
        runner.expect(event.evidence.first?.kind == "user_defaults", "Evidence should decode")
    }

    let lifecycleCollectorEvent = #"{"schema_version":1,"id":"lifecycle-test","occurred_at":"2026-07-27T06:00:00.000Z","recorded_at":"2026-07-27T06:00:00.000Z","category":"hook","action":"codex_lifecycle_session_start","title":"Codex 会话已开始","summary":"本机 Codex 生命周期 Hook 确认会话开始。","status":"success","importance":"routine","certainty":"confirmed","actor":{"type":"hook","id":"codex-workbench-lifecycle","label":"工作台生命周期采集"},"scope":"thread","thread":{"id":"safe-session-123","title":null,"relation":"source"},"source_chain":[],"evidence":[]}"#
    let lifecycleDecoded = LedgerRepository().load(data: Data((lifecycleCollectorEvent + "\n").utf8))
    runner.expect(
        lifecycleDecoded.warnings.isEmpty
            && lifecycleDecoded.events.first?.action == "codex_lifecycle_session_start"
            && lifecycleDecoded.events.first?.actor.type == .hook
            && lifecycleDecoded.events.first?.thread?.id == "safe-session-123",
        "The enhanced lifecycle collector schema should decode through LedgerRepository"
    )

    let malformed = "{not-json}\n" + confirmedEvent + "\n"
    let partial = LedgerRepository().load(data: Data(malformed.utf8))
    runner.expect(partial.events.count == 1, "Malformed rows should not block valid events")
    runner.expect(partial.warnings.count == 1, "Malformed rows should be reported")
    runner.expect(partial.warnings.first?.line == 1, "Warning should identify the bad line")

    let olderDuplicate = confirmedEvent
        .replacingOccurrences(of: "2026-07-14T19:13:00+08:00", with: "2026-07-14T18:13:00+08:00")
        .replacingOccurrences(of: "2026-07-14T19:13:01+08:00", with: "2026-07-14T18:13:01+08:00")
    let newerEvent = confirmedEvent
        .replacingOccurrences(of: "evt-reset", with: "evt-context")
        .replacingOccurrences(of: "2026-07-14T19:13:00+08:00", with: "2026-07-14T20:13:00+08:00")
        .replacingOccurrences(of: "2026-07-14T19:13:01+08:00", with: "2026-07-14T20:13:01+08:00")
    let deduplicated = LedgerRepository().load(
        data: Data(([olderDuplicate, confirmedEvent, newerEvent].joined(separator: "\n") + "\n").utf8),
        limit: 2
    )
    runner.expect(deduplicated.events.count == 2, "Duplicate ids should collapse before limiting")
    runner.expect(deduplicated.events.map(\.id) == ["evt-context", "evt-reset"], "Events should be latest first")
    runner.expect(
        deduplicated.events.last?.summary.contains("100%") == true,
        "The duplicate with the latest recorded time should win"
    )
}
