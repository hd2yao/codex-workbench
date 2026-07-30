import CodexWorkbenchCore
import Foundation

func runLedgerMaintenanceTests(_ runner: inout TestRunner) {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-ledger-maintenance-\(UUID().uuidString)", isDirectory: true)
    let ledgerURL = temporaryDirectory.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let usage = maintenanceEvent(id: "usage", action: "quota_usage_updated")
    let resetTime = maintenanceEvent(id: "reset-time", action: "quota_reset_time_updated")
    let recovery = maintenanceEvent(id: "recovery", action: "official_quota_restored")
    _ = LedgerWriter().append(events: [usage, resetTime, recovery], to: ledgerURL)
    if let handle = try? FileHandle(forWritingTo: ledgerURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("{invalid-line}\n".utf8))
        try? handle.close()
    }

    let first = LedgerMaintenance().prune(
        actions: ["quota_usage_updated", "quota_reset_time_updated"],
        from: ledgerURL
    )
    runner.expect(first.removedCount == 2, "Deprecated quota-noise events should be removed once")

    let loaded = LedgerRepository().load(from: ledgerURL)
    runner.expect(loaded.events.map(\.action) == ["official_quota_restored"], "Important quota events should be preserved")
    runner.expect(loaded.warnings.count == 1, "Ledger maintenance should preserve unrelated malformed lines for diagnosis")

    let second = LedgerMaintenance().prune(
        actions: ["quota_usage_updated", "quota_reset_time_updated"],
        from: ledgerURL
    )
    runner.expect(second.removedCount == 0, "Repeated maintenance should be idempotent")
}

private func maintenanceEvent(id: String, action: String) -> OperationEvent {
    let now = Date(timeIntervalSince1970: 1_000)
    return OperationEvent(
        schemaVersion: 1,
        id: id,
        occurredAt: now,
        recordedAt: now,
        category: .quota,
        action: action,
        title: action,
        summary: action,
        status: .success,
        importance: .important,
        certainty: .confirmed,
        actor: EventActor(type: .system, id: "test", label: "Test")
    )
}
