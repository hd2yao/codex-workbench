import Foundation
import CodexWorkbenchCore

if CommandLine.arguments.contains("--live-dry-run") {
    let snapshot = LocalEvidenceReader().read()
    let events = EvidenceReconciler().events(from: snapshot)
    let categoryCounts = Dictionary(grouping: events, by: \.category)
        .mapValues(\.count)
        .map { "\($0.key.rawValue)=\($0.value)" }
        .sorted()
        .joined(separator: ",")
    print(
        "LIVE_DRY_RUN cards=\(snapshot.contextCards.count) resets=\(snapshot.automaticResets.count) "
            + "lifecycle=\(snapshot.lifecycleRecords.count) events=\(events.count) categories=\(categoryCounts) "
            + "warnings=\(snapshot.warnings.count)"
    )
}

var runner = TestRunner()
runAppContractsTests(&runner)
runWorkbenchAppearancePreferenceTests(&runner)
runTokenCountFormatterTests(&runner)
runChartCalloutPlacementTests(&runner)
runLedgerRepositoryTests(&runner)
runActivityFilterTests(&runner)
runEvidenceReconcilerTests(&runner)
runQuotaObservationTests(&runner)
runCodexMetadataCatalogTests(&runner)
runWorkflowEvidenceTests(&runner)
runWorkflowEventEnrichmentTests(&runner)
runWorkspaceInsightsTests(&runner)
runWorkspaceCatalogPresentationTests(&runner)
runWorkbenchLaunchPolicyTests(&runner)
runWorkbenchVisualAcceptanceTests(&runner)
runObservationStateTests(&runner)
runAppServerNotificationTests(&runner)
runLedgerMaintenanceTests(&runner)
runDesktopClientTargetTests(&runner)
runAccountGatewayTests(&runner)
runAccountUsageTrendTests(&runner)
runAccountRefreshFreshnessTests(&runner)
runAccountOperationEventFactoryTests(&runner)
runAccountDetailPresentationTests(&runner)
runAccountPresentationTests(&runner)
runAccountRuntimePolicyTests(&runner)
runAccountSwitchVerificationTests(&runner)
runAccountRestartPolicyTests(&runner)
runWorkbenchDiagnosticsTests(&runner)
runAutomaticResetPolicyTests(&runner)
runResetCreditNotificationPlanTests(&runner)
runCodexIntegrationTests(&runner)

if runner.failures.isEmpty {
    print("PASS: CodexWorkbenchCoreTests")
} else {
    for failure in runner.failures {
        fputs("FAIL: \(failure)\n", stderr)
    }
    exit(1)
}
