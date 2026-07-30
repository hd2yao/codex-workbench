import CodexWorkbenchCore
import Foundation

func runAccountUsageTrendTests(_ runner: inout TestRunner) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 25))!

    let officialProfile = decodeTrendProfile(
        usage: """
        {
          "dailyUsageBuckets": [
            {"startDate":"2026-07-21","tokens":10},
            {"startDate":"2026-07-23","tokens":20},
            {"startDate":"2026-07-23","tokens":5},
            {"startDate":"2026-07-24","tokens":-9},
            {"startDate":"2026-07-25","tokens":30},
            {"startDate":"2026-07-26","tokens":99},
            {"startDate":"not-a-date","tokens":100}
          ]
        }
        """
    )
    let localSnapshot = decodeTrendLocalSnapshot(
        daily: """
        [
          {"date":"2026-07-24","inputTokens":0,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":400}
        ]
        """
    )

    let official = AccountUsageTrendBuilder.build(
        profile: officialProfile,
        localSnapshot: localSnapshot,
        period: .days7,
        today: today,
        calendar: calendar
    )
    runner.expect(official.points.count == 7, "Seven-day trends should contain seven calendar days")
    runner.expect(
        official.points.map(\.tokens) == [0, 0, 10, 0, 25, 0, 30],
        "Missing days should be zero-filled and duplicate official days should be summed"
    )
    runner.expect(official.source == .official, "Official account buckets should win over local data")
    runner.expect(official.totalTokens == 65, "Trend total should sum the selected period")
    runner.expect(official.averageTokens == 9, "Trend average should use every calendar day")
    runner.expect(official.peak?.tokens == 30, "Trend peak should retain the highest daily value")
    runner.expect(
        official.latestSourceDate == today,
        "Trend freshness should use the latest valid source date"
    )

    let localProfile = decodeTrendProfile(usage: nil)
    let local = AccountUsageTrendBuilder.build(
        profile: localProfile,
        localSnapshot: localSnapshot,
        period: .days14,
        today: today,
        calendar: calendar
    )
    runner.expect(local.points.count == 14, "Fourteen-day trends should contain fourteen calendar days")
    runner.expect(local.source == .localFallback, "Local daily data should be an explicit fallback")
    runner.expect(local.totalTokens == 400, "Local fallback should use local daily totals")
    runner.expect(
        local.points.last(where: { $0.tokens > 0 })?.tokens == 400,
        "Local fallback should map total tokens to the matching day"
    )

    let thirty = AccountUsageTrendBuilder.build(
        profile: officialProfile,
        localSnapshot: nil,
        period: .days30,
        today: today,
        calendar: calendar
    )
    runner.expect(thirty.points.count == 30, "Thirty-day trends should contain thirty calendar days")

    let unavailable = AccountUsageTrendBuilder.build(
        profile: localProfile,
        localSnapshot: nil,
        period: .days7,
        today: today,
        calendar: calendar
    )
    runner.expect(unavailable.points.isEmpty, "Missing sources should not fabricate zero usage")
    runner.expect(unavailable.source == .unavailable, "Missing sources should stay unavailable")
    runner.expect(unavailable.peak == nil, "Missing sources should not fabricate a peak")
}

private func decodeTrendProfile(usage: String?) -> AccountProfile {
    let usageField = usage.map { ",\"usage\":\($0)" } ?? ""
    let data = Data(
        """
        {
          "name":"current",
          "auth":"present",
          "config":"present",
          "rateLimits":{}
          \(usageField)
        }
        """.utf8
    )
    return try! LedgerRepository.decoder().decode(AccountProfile.self, from: data)
}

private func decodeTrendLocalSnapshot(daily: String) -> AccountLocalTokenSnapshot {
    let data = Data(
        """
        {
          "eventCount":1,
          "latestTimestamp":"2026-07-24T12:00:00Z",
          "total":{"inputTokens":0,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":400},
          "daily":\(daily),
          "byModel":[]
        }
        """.utf8
    )
    return try! LedgerRepository.decoder().decode(AccountLocalTokenSnapshot.self, from: data)
}
