import Foundation

public struct AutomaticResetRecord: Equatable, Sendable {
    public let outcome: String?
    public let lastAttemptAt: TimeInterval?
    public let idempotencyKey: String?

    public init(
        outcome: String? = nil,
        lastAttemptAt: TimeInterval? = nil,
        idempotencyKey: String? = nil
    ) {
        self.outcome = outcome
        self.lastAttemptAt = lastAttemptAt
        self.idempotencyKey = idempotencyKey
    }
}

public struct AutomaticResetAttempt: Equatable, Sendable {
    public let profile: String
    public let fingerprint: String
    public let idempotencyKey: String

    public init(profile: String, fingerprint: String, idempotencyKey: String) {
        self.profile = profile
        self.fingerprint = fingerprint
        self.idempotencyKey = idempotencyKey
    }
}

public enum AutomaticResetDecision: Equatable, Sendable {
    case none
    case retryLater(until: TimeInterval)
    case consume(AutomaticResetAttempt)
}

public enum AutomaticResetPolicy {
    public static let retryInterval: TimeInterval = 10 * 60
    public static let terminalOutcomes = Set([
        "reset",
        "alreadyRedeemed",
        "nothingToReset",
        "noCredit",
    ])

    public static func decision(
        profile: AccountProfile,
        now: TimeInterval,
        record: AutomaticResetRecord,
        isInFlight: Bool,
        automationAvailability: AccountAutomationAvailability,
        newIdempotencyKey: String
    ) -> AutomaticResetDecision {
        guard automationAvailability == .available else { return .none }
        guard let fingerprint = fingerprint(profile: profile, now: now) else { return .none }
        if let outcome = record.outcome, terminalOutcomes.contains(outcome) {
            return .none
        }
        if isInFlight {
            return .retryLater(until: now + retryInterval)
        }
        if let lastAttemptAt = record.lastAttemptAt {
            let retryAt = lastAttemptAt + retryInterval
            if retryAt > now {
                return .retryLater(until: retryAt)
            }
        }

        let idempotencyKey = normalized(record.idempotencyKey)
            ?? normalized(newIdempotencyKey)
        guard let idempotencyKey else { return .none }
        return .consume(
            AutomaticResetAttempt(
                profile: profile.name,
                fingerprint: fingerprint,
                idempotencyKey: idempotencyKey
            )
        )
    }

    public static func fingerprint(
        profile: AccountProfile,
        now: TimeInterval
    ) -> String? {
        guard
            let reachedType = normalized(profile.rateLimits.reachedType),
            availableCount(profile: profile) > 0
        else {
            return nil
        }
        let earliestExpiry = profile.resetCreditDetails?.earliestExpiresAt
            ?? profile.rateLimits.resetCredits?.expiresAt
        if let earliestExpiry, earliestExpiry <= now {
            return nil
        }
        let quotaWindow = profile.rateLimits.primary?.resetsAt
            ?? profile.rateLimits.secondary?.resetsAt
            ?? earliestExpiry
            ?? 0
        return "\(profile.name).\(reachedType).\(Int(quotaWindow))"
    }

    private static func availableCount(profile: AccountProfile) -> Int {
        profile.resetCreditDetails?.availableCount
            ?? profile.rateLimits.resetCredits?.availableCount
            ?? profile.rateLimits.creditsAvailable
            ?? 0
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum AutomaticResetStorageKeys {
    public static func actor(fingerprint: String) -> String {
        "automatic-reset.actor.\(fingerprint)"
    }

    public static func outcome(fingerprint: String) -> String {
        "automatic-reset.outcome.\(fingerprint)"
    }

    public static func lastAttempt(fingerprint: String) -> String {
        "automatic-reset.last-attempt.\(fingerprint)"
    }

    public static func idempotency(fingerprint: String) -> String {
        "automatic-reset.idempotency.\(fingerprint)"
    }
}
