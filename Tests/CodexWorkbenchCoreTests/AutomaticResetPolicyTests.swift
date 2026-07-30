import CodexWorkbenchCore
import Foundation

func runAutomaticResetPolicyTests(_ runner: inout TestRunner) {
    let now: TimeInterval = 2_000_000
    let profile = automaticResetProfile(
        reachedType: " primary ",
        availableCount: 2,
        expiry: now + 3_600,
        quotaReset: now + 1_800
    )

    let consume = AutomaticResetPolicy.decision(
        profile: profile,
        now: now,
        record: AutomaticResetRecord(),
        isInFlight: false,
        automationAvailability: .available,
        newIdempotencyKey: "new-stable-key"
    )
    runner.expect(
        consume == .consume(
            AutomaticResetAttempt(
                profile: "hd-master",
                fingerprint: "hd-master.primary.2001800",
                idempotencyKey: "new-stable-key"
            )
        ),
        "Official exhaustion with a valid credit should create one deterministic attempt"
    )

    let expiryAlone = automaticResetProfile(
        reachedType: nil,
        availableCount: 2,
        expiry: now + 60,
        quotaReset: now + 1_800
    )
    runner.expect(
        automaticResetDecision(profile: expiryAlone, now: now) == .none,
        "An expiring credit must never trigger consumption without official exhaustion"
    )

    let noCredit = automaticResetProfile(
        reachedType: "primary",
        availableCount: 0,
        expiry: now + 3_600,
        quotaReset: now + 1_800
    )
    runner.expect(
        automaticResetDecision(profile: noCredit, now: now) == .none,
        "Automatic reset requires an available credit"
    )

    let expired = automaticResetProfile(
        reachedType: "primary",
        availableCount: 1,
        expiry: now,
        quotaReset: now + 1_800
    )
    runner.expect(
        automaticResetDecision(profile: expired, now: now) == .none,
        "An expired credit must not be consumed"
    )

    for outcome in ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"] {
        let terminal = AutomaticResetPolicy.decision(
            profile: profile,
            now: now,
            record: AutomaticResetRecord(outcome: outcome),
            isInFlight: false,
            automationAvailability: .available,
            newIdempotencyKey: "unused"
        )
        runner.expect(terminal == .none, "Terminal outcome \(outcome) should not consume again")
    }

    let throttled = AutomaticResetPolicy.decision(
        profile: profile,
        now: now,
        record: AutomaticResetRecord(lastAttemptAt: now - 599, idempotencyKey: "existing-key"),
        isInFlight: false,
        automationAvailability: .available,
        newIdempotencyKey: "replacement-key"
    )
    runner.expect(
        throttled == .retryLater(until: now + 1),
        "Automatic reset retries should wait a full ten minutes"
    )

    let retry = AutomaticResetPolicy.decision(
        profile: profile,
        now: now,
        record: AutomaticResetRecord(lastAttemptAt: now - 600, idempotencyKey: "existing-key"),
        isInFlight: false,
        automationAvailability: .available,
        newIdempotencyKey: "replacement-key"
    )
    runner.expect(
        retry == .consume(
            AutomaticResetAttempt(
                profile: "hd-master",
                fingerprint: "hd-master.primary.2001800",
                idempotencyKey: "existing-key"
            )
        ),
        "A retry should reuse its persisted idempotency key"
    )

    let paused = AutomaticResetPolicy.decision(
        profile: profile,
        now: now,
        record: AutomaticResetRecord(),
        isInFlight: false,
        automationAvailability: .pausedForLegacyProfileSwitcher,
        newIdempotencyKey: "unused"
    )
    runner.expect(paused == .none, "The cold-backup process must pause all automatic consumption")

    let fingerprint = "hd-master.primary.2001800"
    runner.expect(
        AutomaticResetStorageKeys.actor(fingerprint: fingerprint)
            == "automatic-reset.actor.hd-master.primary.2001800",
        "Producer markers should share the legacy preference domain without changing old keys"
    )
    runner.expect(
        AutomaticResetStorageKeys.outcome(fingerprint: fingerprint)
            == "automatic-reset.outcome.hd-master.primary.2001800",
        "Outcome keys must stay compatible with the legacy preference domain"
    )
    runner.expect(
        AutomaticResetStorageKeys.lastAttempt(fingerprint: fingerprint)
            == "automatic-reset.last-attempt.hd-master.primary.2001800",
        "Retry timestamps must stay compatible with the legacy preference domain"
    )
    runner.expect(
        AutomaticResetStorageKeys.idempotency(fingerprint: fingerprint)
            == "automatic-reset.idempotency.hd-master.primary.2001800",
        "Idempotency keys must stay compatible with the legacy preference domain"
    )

    let claimDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-workbench-reset-claim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: claimDirectory) }
    let claimStore = AutomaticResetClaimStore(directoryURL: claimDirectory)
    let startGate = DispatchSemaphore(value: 0)
    let attempted = DispatchSemaphore(value: 0)
    let releaseWinner = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let backendCallCount = LockedCounter()

    for _ in 0..<2 {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            startGate.wait()
            let claim = claimStore.acquire(fingerprint: fingerprint)
            attempted.signal()
            if let claim {
                backendCallCount.increment()
                releaseWinner.wait()
                withExtendedLifetime(claim) {}
            }
            group.leave()
        }
    }
    startGate.signal()
    startGate.signal()
    attempted.wait()
    attempted.wait()
    releaseWinner.signal()
    group.wait()
    runner.expect(
        backendCallCount.value == 1,
        "Two concurrent app processes must allow only one reset-credit backend call"
    )
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func automaticResetDecision(
    profile: AccountProfile,
    now: TimeInterval
) -> AutomaticResetDecision {
    AutomaticResetPolicy.decision(
        profile: profile,
        now: now,
        record: AutomaticResetRecord(),
        isInFlight: false,
        automationAvailability: .available,
        newIdempotencyKey: "new-key"
    )
}

private func automaticResetProfile(
    reachedType: String?,
    availableCount: Int,
    expiry: TimeInterval?,
    quotaReset: TimeInterval?
) -> AccountProfile {
    AccountProfile(
        name: "hd-master",
        auth: "present",
        config: "present",
        rateLimits: AccountRateLimits(
            primary: AccountQuotaWindow(resetsAt: quotaReset),
            reachedType: reachedType,
            resetCredits: AccountResetCredits(availableCount: availableCount, expiresAt: expiry)
        ),
        resetCreditDetails: AccountResetCreditDetails(
            availableCount: availableCount,
            earliestExpiresAt: expiry
        )
    )
}
