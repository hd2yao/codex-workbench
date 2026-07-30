import Foundation

public enum AccountUsageTrendPeriod: Int, CaseIterable, Equatable, Sendable {
    case days7 = 7
    case days14 = 14
    case days30 = 30

    public var title: String {
        switch self {
        case .days7:
            "近 7 日"
        case .days14:
            "近 14 日"
        case .days30:
            "近 30 日"
        }
    }
}

public enum AccountUsageTrendSource: Equatable, Sendable {
    case official
    case localFallback
    case unavailable

    public var title: String {
        switch self {
        case .official:
            "官方日用量"
        case .localFallback:
            "本地记录（回退）"
        case .unavailable:
            "暂无日用量"
        }
    }
}

public struct AccountUsageTrendPoint: Identifiable, Equatable, Sendable {
    public var id: Date { date }

    public let date: Date
    public let tokens: Int

    public init(date: Date, tokens: Int) {
        self.date = date
        self.tokens = tokens
    }
}

public struct AccountUsageTrend: Equatable, Sendable {
    public let points: [AccountUsageTrendPoint]
    public let source: AccountUsageTrendSource
    public let latestSourceDate: Date?

    public var totalTokens: Int {
        points.reduce(0) { $0 + $1.tokens }
    }

    public var averageTokens: Int {
        guard !points.isEmpty else { return 0 }
        return totalTokens / points.count
    }

    public var peak: AccountUsageTrendPoint? {
        guard totalTokens > 0 else { return nil }
        return points.max {
            if $0.tokens == $1.tokens {
                return $0.date < $1.date
            }
            return $0.tokens < $1.tokens
        }
    }
}

public enum AccountUsageTrendBuilder {
    public static func build(
        profile: AccountProfile,
        localSnapshot: AccountLocalTokenSnapshot?,
        period: AccountUsageTrendPeriod,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> AccountUsageTrend {
        let normalizedToday = calendar.startOfDay(for: today)
        let officialRecords = validRecords(
            profile.usage?.dailyUsageBuckets?.map { ($0.startDate, $0.tokens) } ?? [],
            today: normalizedToday,
            calendar: calendar
        )
        let localRecords = validRecords(
            localSnapshot?.daily?.map { ($0.date, $0.totalTokens) } ?? [],
            today: normalizedToday,
            calendar: calendar
        )

        let records: [(date: Date, tokens: Int)]
        let source: AccountUsageTrendSource
        if !officialRecords.isEmpty {
            records = officialRecords
            source = .official
        } else if !localRecords.isEmpty {
            records = localRecords
            source = .localFallback
        } else {
            return AccountUsageTrend(points: [], source: .unavailable, latestSourceDate: nil)
        }

        let firstDate = calendar.date(
            byAdding: .day,
            value: -(period.rawValue - 1),
            to: normalizedToday
        ) ?? normalizedToday
        let totalsByDate = Dictionary(grouping: records, by: \.date)
            .mapValues { values in values.reduce(0) { $0 + $1.tokens } }
        let points = (0..<period.rawValue).compactMap { offset -> AccountUsageTrendPoint? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDate) else {
                return nil
            }
            return AccountUsageTrendPoint(date: date, tokens: totalsByDate[date, default: 0])
        }

        return AccountUsageTrend(
            points: points,
            source: source,
            latestSourceDate: records.map(\.date).max()
        )
    }

    private static func validRecords(
        _ values: [(date: String, tokens: Int)],
        today: Date,
        calendar: Calendar
    ) -> [(date: Date, tokens: Int)] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false

        return values.compactMap { value in
            guard
                value.tokens >= 0,
                let parsed = formatter.date(from: value.date)
            else {
                return nil
            }
            let date = calendar.startOfDay(for: parsed)
            guard date <= today else { return nil }
            return (date, value.tokens)
        }
    }
}
