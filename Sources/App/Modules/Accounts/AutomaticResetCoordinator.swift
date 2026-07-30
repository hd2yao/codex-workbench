import CodexWorkbenchCore
import Foundation

final class AutomaticResetPreferenceStore {
    static let legacySuiteName = AccountRuntimePolicy.legacyProfileSwitcherBundleIdentifier

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: legacySuiteName)) {
        self.defaults = defaults ?? .standard
    }

    func record(fingerprint: String) -> AutomaticResetRecord {
        defaults.synchronize()
        let lastAttemptKey = AutomaticResetStorageKeys.lastAttempt(fingerprint: fingerprint)
        let lastAttempt = defaults.object(forKey: lastAttemptKey) == nil
            ? nil
            : defaults.double(forKey: lastAttemptKey)
        return AutomaticResetRecord(
            outcome: defaults.string(
                forKey: AutomaticResetStorageKeys.outcome(fingerprint: fingerprint)
            ),
            lastAttemptAt: lastAttempt,
            idempotencyKey: defaults.string(
                forKey: AutomaticResetStorageKeys.idempotency(fingerprint: fingerprint)
            )
        )
    }

    func begin(attempt: AutomaticResetAttempt, now: TimeInterval) {
        defaults.set(
            "codex-workbench",
            forKey: AutomaticResetStorageKeys.actor(fingerprint: attempt.fingerprint)
        )
        defaults.set(
            attempt.idempotencyKey,
            forKey: AutomaticResetStorageKeys.idempotency(fingerprint: attempt.fingerprint)
        )
        defaults.set(
            now,
            forKey: AutomaticResetStorageKeys.lastAttempt(fingerprint: attempt.fingerprint)
        )
        defaults.synchronize()
    }

    func finish(attempt: AutomaticResetAttempt, outcome: String) {
        defaults.set(
            outcome,
            forKey: AutomaticResetStorageKeys.outcome(fingerprint: attempt.fingerprint)
        )
        defaults.synchronize()
    }
}

@MainActor
final class AutomaticResetCoordinator {
    private let store: AutomaticResetPreferenceStore
    private let notifications: ResetCreditNotificationService
    private let claimStore: AutomaticResetClaimStore
    private let availabilityProvider: @MainActor @Sendable () -> AccountAutomationAvailability
    private var inFlight = Set<String>()

    init(
        store: AutomaticResetPreferenceStore = AutomaticResetPreferenceStore(),
        notifications: ResetCreditNotificationService = ResetCreditNotificationService(),
        claimStore: AutomaticResetClaimStore = .shared(),
        availabilityProvider: @escaping @MainActor @Sendable () -> AccountAutomationAvailability = {
            AccountRuntimePolicy.automationAvailability(
                legacyProfileSwitcherRunning: AccountRuntimeServices.legacyProfileSwitcherIsRunning()
            )
        }
    ) {
        self.store = store
        self.notifications = notifications
        self.claimStore = claimStore
        self.availabilityProvider = availabilityProvider
    }

    func start() {
        notifications.requestAuthorization()
    }

    func process(
        payload: AccountDashboardPayload,
        gateway: AccountGateway?,
        onTerminalOutcome: @escaping @MainActor (AutomaticResetAttempt, AccountResetCreditConsumeResult) -> Void
    ) {
        let runtimeAvailability = availabilityProvider()
        let availability = runtimeAvailability == .available
            ? AccountRuntimePolicy.automationAvailability(
                accountMode: payload.accountMode,
                storageMode: payload.accountStorage.mode,
                legacyProfileSwitcherRunning: false
            )
            : runtimeAvailability
        guard availability != .pausedForLegacyProfileSwitcher else {
            notifications.clearScheduledReminders()
            return
        }
        notifications.sync(payload: payload)
        guard availability == .available else { return }
        guard payload.accountMode == .managedProfiles else { return }
        guard let gateway else { return }
        let now = Date().timeIntervalSince1970

        for profile in payload.profiles {
            guard availabilityProvider() == .available else {
                notifications.clearScheduledReminders()
                return
            }
            guard let fingerprint = AutomaticResetPolicy.fingerprint(profile: profile, now: now) else {
                continue
            }
            guard let claim = claimStore.acquire(fingerprint: fingerprint) else { continue }
            guard availabilityProvider() == .available else {
                claim.release()
                notifications.clearScheduledReminders()
                return
            }
            let decision = AutomaticResetPolicy.decision(
                profile: profile,
                now: now,
                record: store.record(fingerprint: fingerprint),
                isInFlight: inFlight.contains(fingerprint),
                automationAvailability: availability,
                newIdempotencyKey: UUID().uuidString
            )
            guard case .consume(let attempt) = decision else {
                claim.release()
                continue
            }
            store.begin(attempt: attempt, now: now)
            inFlight.insert(fingerprint)

            Task { [claim] in
                defer { claim.release() }
                guard
                    payload.accountMode == .managedProfiles,
                    payload.accountStorage.mode != .unifiedVault,
                    availabilityProvider() == .available
                else {
                    inFlight.remove(fingerprint)
                    notifications.clearScheduledReminders()
                    return
                }
                let result = await Task.detached(priority: .userInitiated) {
                    try? gateway.consumeResetCredit(
                        profile: attempt.profile,
                        idempotencyKey: attempt.idempotencyKey
                    )
                }.value
                inFlight.remove(fingerprint)
                guard
                    let result,
                    result.ok,
                    let outcome = result.outcome,
                    AutomaticResetPolicy.terminalOutcomes.contains(outcome)
                else {
                    return
                }
                store.finish(attempt: attempt, outcome: outcome)
                if outcome == "reset" || outcome == "alreadyRedeemed" {
                    notifications.notifyAutomaticReset(profile: attempt.profile, outcome: outcome)
                }
                onTerminalOutcome(attempt, result)
            }
        }
    }
}
