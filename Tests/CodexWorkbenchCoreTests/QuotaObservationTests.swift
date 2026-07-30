import CodexWorkbenchCore
import Foundation

func runQuotaObservationTests(_ runner: inout TestRunner) {
    let factory = QuotaEventFactory()
    let resetAt = Date(timeIntervalSince1970: 10_000)

    let scheduledPrevious = QuotaObservation(
        profile: "hd-master",
        observedAt: Date(timeIntervalSince1970: 9_900),
        remainingPercent: 2,
        resetsAt: resetAt,
        resetCredits: 3,
        reachedType: "primary"
    )
    let scheduledCurrent = QuotaObservation(
        profile: "hd-master",
        observedAt: Date(timeIntervalSince1970: 10_060),
        remainingPercent: 100,
        resetsAt: Date(timeIntervalSince1970: 20_000),
        resetCredits: 3,
        reachedType: nil
    )
    let scheduled = factory.events(previous: scheduledPrevious, current: scheduledCurrent)
    runner.expect(
        scheduled.contains { $0.action == "quota_window_refreshed" && $0.importance == .routine },
        "A full recovery near the previous resetsAt should be a routine scheduled refresh"
    )
    runner.expect(
        scheduled.contains { $0.title == "额度已按计划刷新" },
        "Scheduled refresh should use an explicit user-facing title"
    )

    let officialPrevious = QuotaObservation(
        profile: "hd-master",
        observedAt: Date(timeIntervalSince1970: 11_000),
        remainingPercent: 2,
        resetsAt: Date(timeIntervalSince1970: 20_000),
        resetCredits: 3,
        reachedType: nil
    )
    let officialCurrent = QuotaObservation(
        profile: "hd-master",
        observedAt: Date(timeIntervalSince1970: 11_060),
        remainingPercent: 100,
        resetsAt: Date(timeIntervalSince1970: 20_000),
        resetCredits: 3,
        reachedType: nil
    )
    let official = factory.events(previous: officialPrevious, current: officialCurrent)
    runner.expect(
        official.contains { $0.action == "official_quota_restored" && $0.importance == .important },
        "A full recovery outside the scheduled window should be an important official-side recovery"
    )
    runner.expect(
        official.contains { $0.summary.contains("官方未提供原因") },
        "Official-side recovery must not invent a compensation reason"
    )

    let localReset = makeQuotaResetEvent(
        profile: "hd-master",
        occurredAt: Date(timeIntervalSince1970: 11_050)
    )
    let local = factory.events(
        previous: officialPrevious,
        current: officialCurrent,
        localResetEvents: [localReset]
    )
    runner.expect(
        local.contains { $0.action == "quota_restored_by_credit" && $0.importance == .critical },
        "A nearby local reset-credit event should explain the recovery"
    )
    runner.expect(
        local.contains { $0.action == "official_quota_restored" } == false,
        "A locally explained recovery must not also be labeled official-side recovery"
    )

    let creditsIncreased = factory.events(
        previous: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 12_000),
            remainingPercent: 50,
            resetsAt: resetAt,
            resetCredits: 3,
            reachedType: nil
        ),
        current: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 12_060),
            remainingPercent: 50,
            resetsAt: resetAt,
            resetCredits: 4,
            reachedType: nil
        )
    )
    runner.expect(
        creditsIncreased.contains { $0.action == "reset_credits_increased" && $0.summary.contains("3 次增加到 4 次") },
        "An official reset-credit increase should retain exact before and after counts"
    )

    let creditsDecreased = factory.events(
        previous: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 13_000),
            remainingPercent: 50,
            resetsAt: resetAt,
            resetCredits: 4,
            reachedType: nil
        ),
        current: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 13_060),
            remainingPercent: 50,
            resetsAt: resetAt,
            resetCredits: 3,
            reachedType: nil
        )
    )
    runner.expect(
        creditsDecreased.contains { $0.action == "reset_credits_decreased" },
        "An unexplained reset-credit decrease should still be logged"
    )

    let usageChanged = factory.events(
        previous: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 14_000),
            remainingPercent: 52,
            resetsAt: resetAt,
            resetCredits: 3,
            reachedType: nil
        ),
        current: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 14_060),
            remainingPercent: 48,
            resetsAt: resetAt,
            resetCredits: 3,
            reachedType: nil
        )
    )
    runner.expect(
        usageChanged.isEmpty,
        "Ordinary quota consumption should update the baseline without creating timeline noise"
    )

    let exhausted = factory.events(
        previous: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 14_100),
            remainingPercent: 2,
            resetsAt: resetAt,
            resetCredits: 3,
            reachedType: nil
        ),
        current: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 14_160),
            remainingPercent: 0,
            resetsAt: resetAt,
            resetCredits: 3,
            reachedType: nil
        )
    )
    runner.expect(
        exhausted.contains { $0.action == "quota_limit_reached" && $0.status == .failure },
        "Reaching zero remaining quota should be logged even when the official reached type is absent"
    )

    let rollingResetTime = factory.events(
        previous: QuotaObservation(
            profile: "unused-profile",
            observedAt: Date(timeIntervalSince1970: 15_000),
            remainingPercent: 100,
            resetsAt: Date(timeIntervalSince1970: 25_000),
            resetCredits: 1,
            reachedType: nil
        ),
        current: QuotaObservation(
            profile: "unused-profile",
            observedAt: Date(timeIntervalSince1970: 15_060),
            remainingPercent: 100,
            resetsAt: Date(timeIntervalSince1970: 25_060),
            resetCredits: 1,
            reachedType: nil
        )
    )
    runner.expect(
        rollingResetTime.contains { $0.action == "quota_reset_time_updated" } == false,
        "A reset deadline that moves exactly with observation time is a derived rolling value, not an event"
    )

    let standaloneResetTimeChange = factory.events(
        previous: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 16_000),
            remainingPercent: 50,
            resetsAt: Date(timeIntervalSince1970: 26_000),
            resetCredits: 3,
            reachedType: nil
        ),
        current: QuotaObservation(
            profile: "hd-master",
            observedAt: Date(timeIntervalSince1970: 16_060),
            remainingPercent: 50,
            resetsAt: Date(timeIntervalSince1970: 27_000),
            resetCredits: 3,
            reachedType: nil
        )
    )
    runner.expect(
        standaloneResetTimeChange.isEmpty,
        "A reset deadline change without an actual recovery should not create quota timeline noise"
    )

    let unchanged = factory.events(previous: officialCurrent, current: QuotaObservation(
        profile: officialCurrent.profile,
        observedAt: Date(timeIntervalSince1970: 11_120),
        remainingPercent: officialCurrent.remainingPercent,
        resetsAt: officialCurrent.resetsAt,
        resetCredits: officialCurrent.resetCredits,
        reachedType: officialCurrent.reachedType
    ))
    runner.expect(unchanged.isEmpty, "An identical quota state should not create a duplicate event")
}

private func makeQuotaResetEvent(profile: String, occurredAt: Date) -> OperationEvent {
    OperationEvent(
        schemaVersion: 1,
        id: "evt-local-reset",
        occurredAt: occurredAt,
        recordedAt: occurredAt,
        category: .quota,
        action: "reset_credit_consumed",
        title: "已使用 1 次额度重置",
        summary: "本地重置状态机已完成。",
        status: .success,
        importance: .critical,
        certainty: .confirmed,
        actor: EventActor(type: .app, id: "codex-profile-switcher", label: "Profile Switcher"),
        account: EventAccount(profile: profile)
    )
}
