import Charts
import CodexWorkbenchCore
import SwiftUI

struct AccountsView: View {
    @ObservedObject var model: WorkbenchAppModel
    @State private var showingDiagnostics = false

    private var details: AccountDetailsPresentation {
        AccountPresentationBuilder.details(payload: model.accountPayload)
    }

    private var roles: AccountRolesPresentation {
        AccountPresentationBuilder.roles(payload: model.accountPayload)
    }

    private var storage: AccountStoragePresentation {
        AccountPresentationBuilder.storage(payload: model.accountPayload)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                PageHeader(
                    title: "账号与额度",
                    description: "官方账号状态、预期桌面默认账号、三个独立角色、额度与账号存储。",
                    trailing: AnyView(
                        Button("刷新额度") {
                            Task { await model.refreshAll(refreshResetCredits: true) }
                        }
                        .disabled(model.isRefreshing || model.isVisualAcceptanceMode)
                        .accessibilityRepresentation {
                            Button("刷新账号额度") {
                                Task { await model.refreshAll(refreshResetCredits: true) }
                            }
                            .disabled(model.isRefreshing || model.isVisualAcceptanceMode)
                        }
                    )
                )

                if let banner = model.visualAcceptanceBanner {
                    AccountNotice(
                        title: "视觉验收模式",
                        message: banner,
                        color: .blue,
                        systemImage: "eye.fill"
                    )
                }

                if let stage = model.accountSwitchStage {
                    AccountNotice(
                        title: switchNoticeTitle(stage),
                        message: "目标账号：\(AccountPresentationBuilder.profileDisplayName(stage.profile))。请稍候，不要重复操作。",
                        color: .blue,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

                if let stage = model.accountRestartStage {
                    AccountNotice(
                        title: restartNoticeTitle(stage),
                        message: "工作台正在安全重启 \(model.desktopClientDisplayName)，并核对新进程身份与预期桌面默认账号。",
                        color: .blue,
                        systemImage: "arrow.clockwise.circle.fill"
                    )
                }

                if model.isLegacyProfileSwitcherRunning {
                    AccountNotice(
                        title: "冷备 App 正在运行",
                        message: "为避免重复提醒或自动使用重置卡，工作台的账号自动化已暂停。退出旧 Profile Switcher 后刷新即可恢复。",
                        color: .orange,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                if let error = model.accountError {
                    AccountNotice(
                        title: model.accountErrorNoticeTitle,
                        message: error,
                        color: .orange,
                        systemImage: "exclamationmark.circle.fill"
                    )
                    if model.canRecoverAccountVault || model.isRecoveringAccountVault {
                        Button(action: model.recoverAccountVault) {
                            HStack(spacing: WorkbenchSpacing.xs) {
                                if model.isRecoveringAccountVault {
                                    ProgressView().controlSize(.small)
                                }
                                Text(
                                    model.isRecoveringAccountVault
                                        ? "正在恢复账号库"
                                        : "退出所有客户端后恢复账号库"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isRecoveringAccountVault)
                    }
                }

                if let current = details.currentProfile {
                    CurrentAccountSection(
                        profile: current,
                        payload: model.accountPayload,
                        runtime: model.runtimePresentation,
                        clientDisplayName: model.desktopClientDisplayName,
                        clientRestartLabel: model.desktopClientRestartLabel,
                        clientIdentityDetail: model.desktopClientIdentityDetail,
                        restartStage: model.accountRestartStage,
                        restartDisabled: model.isVisualAcceptanceMode
                            || model.accountSwitchStage != nil
                            || model.desktopClientTarget == nil,
                        onRestart: model.requestRestartCurrentCodex
                    )

                    ResetCreditsSection(
                        profile: current,
                        cards: details.currentResetCards
                    )

                    AccountUsageSection(
                        profile: current,
                        localSnapshot: model.accountPayload?.localSnapshot
                    )
                } else if model.isRefreshing {
                    SurfaceCard {
                        HStack(spacing: WorkbenchSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("正在读取官方账号状态、额度与桌面默认账号…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92)
                    }
                } else {
                    SurfaceCard {
                        QuietEmptyState(
                            systemImage: "person.crop.circle.badge.questionmark",
                            title: "桌面默认账号未知",
                            message: "工作台没有拿到可靠的官方账号状态，因此不会把最近任务或统计归因账号当作桌面默认账号。"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }

                AccountRolesSection(roles: roles)

                AccountStorageSection(
                    presentation: storage,
                    clientIsRunning: model.hasRunningDesktopClients,
                    legacyProfileSwitcherRunning: model.isLegacyProfileSwitcherRunning,
                    isMigrating: model.isMigratingLegacyProfiles,
                    onMigrate: model.requestLegacyProfileMigration
                )

                if model.accountPayload?.accountMode == .managedProfiles {
                    OtherAccountsSection(
                        profiles: details.otherProfiles,
                        currentProfile: model.currentProfileName,
                        clientDisplayName: model.desktopClientDisplayName,
                        switchStage: model.accountSwitchStage,
                        switchingDisabled: model.isVisualAcceptanceMode
                            || model.accountRestartStage != nil,
                        onSwitch: model.switchProfile
                    )
                }

                AccountDiagnosticsSection(
                    payload: model.accountPayload,
                    onOpen: {
                        model.refreshDiagnostics()
                        showingDiagnostics = true
                    }
                )
            }
            .padding(.horizontal, WorkbenchSpacing.lg)
            .padding(.vertical, WorkbenchSpacing.lg)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView(model: model)
        }
        .confirmationDialog(
            "确认\(model.desktopClientRestartLabel)",
            isPresented: restartConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) { model.cancelRestartCurrentCodex() }
            Button("仍然重启", role: .destructive) { model.confirmRestartCurrentCodex() }
        } message: {
            Text(restartConfirmationMessage)
        }
        .confirmationDialog(
            "迁移旧 Profiles 到 Codex Home",
            isPresented: legacyMigrationConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) {
                model.cancelLegacyProfileMigration()
            }
            Button("迁移并保留旧目录") {
                model.confirmLegacyProfileMigration()
            }
        } message: {
            Text(legacyMigrationConfirmationMessage)
        }
        .onAppear {
            if model.visualAcceptanceShowsDiagnostics {
                showingDiagnostics = true
            }
        }
        .accessibilityIdentifier("accounts-page")
    }

    private func switchNoticeTitle(_ stage: AccountSwitchStage) -> String {
        switch stage {
        case .switching:
            "正在切换登录账号"
        case .verifying:
            "正在核对桌面默认账号"
        }
    }

    private func restartNoticeTitle(_ stage: AccountRestartStage) -> String {
        switch stage {
        case .preparing: "正在准备重启"
        case .quitting: "正在安全退出 \(model.desktopClientDisplayName)"
        case .launching: "正在重新启动 \(model.desktopClientDisplayName)"
        case .verifying: "正在核对默认账号"
        }
    }

    private var restartConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.accountRestartConfirmation != nil },
            set: { isPresented in
                if !isPresented, model.accountRestartConfirmation != nil {
                    model.cancelRestartCurrentCodex()
                }
            }
        )
    }

    private var restartConfirmationMessage: String {
        switch model.accountRestartConfirmation {
        case .runningTask:
            "\(model.desktopClientDisplayName) 正在运行任务。重启会中断当前任务，确认仍要继续吗？"
        case .waitingTask:
            "\(model.desktopClientDisplayName) 有待接手任务。重启可能中断尚未完成的状态，确认仍要继续吗？"
        case .unknownState:
            "当前运行状态无法可靠确认。为避免误中断，只有明确确认后才会重启。"
        case nil:
            ""
        }
    }

    private var legacyMigrationConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.legacyMigrationPreview != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelLegacyProfileMigration()
                }
            }
        )
    }

    private var legacyMigrationConfirmationMessage: String {
        guard let preview = model.legacyMigrationPreview else { return "" }
        return "将导入 \(preview.plannedImportCount) 个账号，去重 \(preview.deduplicatedProfiles.count) 个重复账号。当前认证会改为普通工作文件；旧 Profiles 不会删除。"
    }
}

private struct CurrentAccountSection: View {
    let profile: AccountProfile
    let payload: AccountDashboardPayload?
    let runtime: AccountRuntimePresentation
    let clientDisplayName: String
    let clientRestartLabel: String
    let clientIdentityDetail: String
    let restartStage: AccountRestartStage?
    let restartDisabled: Bool
    let onRestart: () -> Void

    var body: some View {
        GroupedPanel {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(AccountPresentationBuilder.profileDisplayName(profile.name))
                                .font(.system(size: 18, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            StatusChip("预期桌面默认账号", color: .secondary, systemImage: "checkmark.circle.fill")
                        }
                        Text(profile.name == "local-default" ? "默认 Codex home" : profile.name)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusChip(
                            runtime.label,
                            color: runtimeColor,
                            systemImage: runtime.symbol
                        )
                        Text(managedText)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Button(action: onRestart) {
                            if restartStage != nil {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在重启")
                                }
                            } else {
                                Label(clientRestartLabel, systemImage: "arrow.clockwise.circle")
                            }
                        }
                        .controlSize(.small)
                        .disabled(restartDisabled || restartStage != nil)
                        .accessibilityLabel(
                            restartStage == nil
                                ? "重启当前 \(clientDisplayName) 账号"
                                : "正在重启 \(clientDisplayName)"
                        )
                        .accessibilityHint("空闲时直接重启；有运行中或待接手任务时先确认风险")
                    }
                }
                .padding(.horizontal, WorkbenchSpacing.md)
                .padding(.top, WorkbenchSpacing.md)

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                        quotaCells
                    }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        quotaCells
                    }
                }
                .padding(.horizontal, WorkbenchSpacing.md)

                Divider()

                HStack(spacing: WorkbenchSpacing.md) {
                    Label(planText, systemImage: "person.text.rectangle")
                    Label(statusText, systemImage: "checkmark.shield")
                    if profile.remoteStale == true {
                        Label("远端数据为暂存", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(Color.orange)
                    }
                }
                .font(
                    .system(size: WorkbenchInterfaceContract.microSize)
                )
                .foregroundStyle(.secondary)
                .padding(.horizontal, WorkbenchSpacing.md)

                Text(clientIdentityDetail)
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.microSize,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.bottom, WorkbenchSpacing.md)
            }
        }
    }

    @ViewBuilder
    private var quotaCells: some View {
        Group {
                    AccountQuotaTile(
                        title: quotaTitle(profile.rateLimits.primary, fallback: "主要额度"),
                        window: profile.rateLimits.primary
                    )
                    Divider()
                    AccountQuotaTile(
                        title: quotaTitle(profile.rateLimits.secondary, fallback: "其他额度"),
                        window: profile.rateLimits.secondary
                    )
                    Divider()
                    ResetCreditSummaryTile(profile: profile)
        }
    }

    private var managedText: String {
        if payload?.accountMode == .localDefault { return "本机当前账号" }
        return payload?.desktopStatus?.managed == true ? "登录状态已接管" : "登录状态未接管"
    }

    private var planText: String {
        "套餐：\(profile.account?.planType?.uppercased() ?? profile.rateLimits.planType?.uppercased() ?? "未知")"
    }

    private var statusText: String {
        profile.auth == "present" && profile.config == "present" ? "认证与配置完整" : "账号文件不完整"
    }

    private var runtimeColor: Color {
        switch runtime.state {
        case "running": .green
        case "waiting": .orange
        default: .secondary
        }
    }

    private func quotaTitle(_ window: AccountQuotaWindow?, fallback: String) -> String {
        AccountPresentationBuilder.quotaTitle(
            profileName: profile.name,
            window: window,
            fallback: fallback
        )
    }
}

private struct AccountQuotaTile: View {
    let title: String
    let window: AccountQuotaWindow?

    private var remaining: Double? { window?.remainingPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.workbenchBorder.opacity(0.5))
                    Capsule()
                        .fill(quotaColor)
                        .frame(width: proxy.size.width * max(0, min(1, (remaining ?? 0) / 100)))
                }
            }
            .frame(height: 6)
            Text(resetText)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
    }

    private var resetText: String {
        guard let date = window?.resetsAtDate else { return "重置时间未知" }
        return "重置于 \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var quotaColor: Color {
        guard let remaining else { return .secondary }
        if remaining <= 10 { return .red }
        if remaining <= 30 { return .orange }
        return .accentColor
    }
}

private struct ResetCreditSummaryTile: View {
    let profile: AccountProfile

    private var count: Int? {
        profile.resetCreditDetails?.availableCount
            ?? profile.rateLimits.resetCredits?.availableCount
            ?? profile.rateLimits.creditsAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("可用重置卡")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(count.map(String.init) ?? "--")
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
            Text(expiryText)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
    }

    private var expiryText: String {
        guard
            let value = profile.resetCreditDetails?.earliestExpiresAt
                ?? profile.rateLimits.resetCredits?.expiresAt
        else {
            return "到期时间未知"
        }
        let date = Date(timeIntervalSince1970: value)
        return "最早于 \(date.formatted(date: .abbreviated, time: .shortened)) 到期"
    }
}

private struct ResetCreditsSection: View {
    let profile: AccountProfile
    let cards: [AccountResetCreditCard]

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle("重置卡明细", detail: cards.isEmpty ? nil : "\(cards.count) 张记录")
            GroupedPanel {
                if cards.isEmpty {
                    HStack(spacing: WorkbenchSpacing.sm) {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("暂无逐张明细")
                                .font(.system(size: 11, weight: .medium))
                            Text(profile.resetCreditError ?? "后端没有返回可展示的重置卡记录。")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(WorkbenchSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(cards.enumerated()), id: \.element.stableID) { index, card in
                        ResetCreditRow(card: card)
                        if index < cards.count - 1 {
                            Divider().padding(.leading, WorkbenchSpacing.md)
                        }
                    }
                }
            }
        }
    }
}

private struct ResetCreditRow: View {
    let card: AccountResetCreditCard

    var body: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title ?? "额度重置卡")
                    .font(.system(size: 11, weight: .medium))
                Text(card.description ?? "可在官方确认额度耗尽后恢复可用额度")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: WorkbenchSpacing.md)
            VStack(alignment: .trailing, spacing: 3) {
                StatusChip(statusText, color: statusColor, systemImage: statusSymbol)
                Text(expiryText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if card.used == true { return "已使用" }
        if let expiry = card.expiresAt, expiry <= Date().timeIntervalSince1970 { return "已过期" }
        return "可用"
    }

    private var statusColor: Color {
        statusText == "可用" ? .green : .secondary
    }

    private var statusSymbol: String {
        statusText == "可用" ? "checkmark.circle.fill" : "circle.slash"
    }

    private var expiryText: String {
        guard let expiry = card.expiresAt else { return "到期时间未知" }
        return "到期：\(Date(timeIntervalSince1970: expiry).formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct AccountUsageSection: View {
    let profile: AccountProfile
    let localSnapshot: AccountLocalTokenSnapshot?

    @State private var period: AccountUsageTrendPeriod = .days7
    @State private var selectedDate: Date?

    private var trend: AccountUsageTrend {
        AccountUsageTrendBuilder.build(
            profile: profile,
            localSnapshot: localSnapshot,
            period: period
        )
    }

    private var highlightedPoint: AccountUsageTrendPoint? {
        guard let selectedDate else { return nil }
        return trend.points.min {
            abs($0.date.timeIntervalSince(selectedDate))
                < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(
                "账号用量趋势",
                detail: "当前账号 · \(AccountPresentationBuilder.profileDisplayName(profile.name))"
            )
            GroupedPanel {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: WorkbenchSpacing.md) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("每日 Tokens")
                                .font(.system(size: 12, weight: .semibold))
                            Text(sourceDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("显示周期", selection: $period) {
                            ForEach(AccountUsageTrendPeriod.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 236)
                        .accessibilityLabel("用量显示周期")
                    }
                    .padding(.horizontal, WorkbenchSpacing.md)
                    .padding(.top, WorkbenchSpacing.md)
                    .padding(.bottom, WorkbenchSpacing.sm)

                    Divider()

                    if trend.points.isEmpty {
                        QuietEmptyState(
                            systemImage: "chart.xyaxis.line",
                            title: "暂无每日用量",
                            message: "官方账号与本地任务记录都没有可用于绘图的每日 Tokens。"
                        )
                        .frame(maxWidth: .infinity, minHeight: 190)
                    } else {
                        interactiveChart
                            .frame(height: 224)
                            .padding(.horizontal, WorkbenchSpacing.md)
                            .padding(.vertical, WorkbenchSpacing.sm)
                            .accessibilityIdentifier("account-usage-chart")
                    }

                    if let highlightedPoint {
                        Divider()
                        selectedDayDetail(highlightedPoint)
                    }

                    Divider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            summaryCells
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            summaryCells
                        }
                    }
                }
            }
        }
        .onChange(of: period) { _ in selectedDate = nil }
    }

    @ViewBuilder
    private var interactiveChart: some View {
        if #available(macOS 14.0, *) {
            baseChart
                .chartXSelection(value: $selectedDate)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        usageInteractionOverlay(proxy: proxy, geometry: geometry)
                    }
                }
        } else {
            baseChart
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        usageInteractionOverlay(proxy: proxy, geometry: geometry)
                    }
                }
        }
    }

    private func usageInteractionOverlay(
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        let plotFrame = geometry[proxy.plotAreaFrame]
                        let xPosition = location.x - plotFrame.origin.x
                        guard
                            xPosition >= 0,
                            xPosition <= plotFrame.width,
                            let date: Date = proxy.value(atX: xPosition)
                        else {
                            selectedDate = nil
                            return
                        }
                        selectedDate = date
                    case .ended:
                        selectedDate = nil
                    }
                }
            usageCallout(proxy: proxy, geometry: geometry)
        }
    }

    @ViewBuilder
    private func usageCallout(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        if let highlightedPoint,
           let xOffset = proxy.position(forX: highlightedPoint.date),
           let yOffset = proxy.position(forY: highlightedPoint.tokens)
        {
            let plotFrame = geometry[proxy.plotAreaFrame]
            let anchor = CGPoint(x: plotFrame.minX + xOffset, y: plotFrame.minY + yOffset)
            let placement = ChartCalloutPlacement.place(
                point: anchor,
                calloutSize: ChartCalloutCard.defaultSize,
                plotFrame: plotFrame
            )
            if placement.fits {
                ChartCalloutCard(
                    dateText: highlightedPoint.date.formatted(.dateTime.month().day()),
                    exactText: "\(TokenCountFormatter.exact(highlightedPoint.tokens)) Tokens",
                    magnitudeText: "约 \(TokenCountFormatter.chinese(highlightedPoint.tokens))"
                )
                .position(placement.center)
                .allowsHitTesting(false)
                .accessibilityLabel(TokenCountFormatter.accessibility(highlightedPoint.tokens))
            }
        }
    }

    private func selectedDayDetail(_ point: AccountUsageTrendPoint) -> some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(Color.accentColor)
            Text(point.date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11, weight: .medium))
            Text("\(TokenCountFormatter.exact(point.tokens)) Tokens")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text("约 \(TokenCountFormatter.chinese(point.tokens))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, WorkbenchSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(point.date.formatted(date: .abbreviated, time: .omitted))：\(TokenCountFormatter.accessibility(point.tokens))"
        )
        .accessibilityIdentifier("account-usage-selected-day-detail")
    }

    private var baseChart: some View {
        Chart {
            ForEach(trend.points) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.14),
                            Color.accentColor.opacity(0.01),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }

            if let peak = trend.peak {
                PointMark(
                    x: .value("峰值日期", peak.date),
                    y: .value("峰值 Tokens", peak.tokens)
                )
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .symbolSize(26)
            }

            if let highlightedPoint {
                RuleMark(x: .value("所选日期", highlightedPoint.date))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(
                    x: .value("所选日期", highlightedPoint.date),
                    y: .value("所选 Tokens", highlightedPoint.tokens)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(42)
            }
        }
        .chartYScale(domain: 0...chartMaximum)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: axisStride)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.08))
                AxisTick()
                    .foregroundStyle(Color.secondary.opacity(0.35))
                AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.system(size: 9, design: .monospaced))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(TokenCountFormatter.chinese(tokens))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.secondary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    @ViewBuilder
    private var summaryCells: some View {
        Group {
            MetricValue(
                title: "今日",
                value: chinese(trend.points.last?.tokens),
                spokenDetail: spokenDetail(trend.points.last?.tokens)
            )
            Divider()
            MetricValue(
                title: "\(period.title)合计",
                value: chinese(trend.totalTokens),
                spokenDetail: spokenDetail(trend.totalTokens)
            )
            Divider()
            MetricValue(
                title: "日均",
                value: chinese(trend.averageTokens),
                spokenDetail: spokenDetail(trend.averageTokens)
            )
            Divider()
            MetricValue(
                title: "单日峰值",
                value: chinese(trend.peak?.tokens),
                spokenDetail: spokenDetail(trend.peak?.tokens)
            )
        }
    }

    private var sourceDetail: String {
        guard let latest = trend.latestSourceDate else { return trend.source.title }
        return "\(trend.source.title) · 更新至 \(latest.formatted(.dateTime.month().day()))"
    }

    private var axisStride: Int {
        switch period {
        case .days7: 1
        case .days14: 2
        case .days30: 5
        }
    }

    private var chartMaximum: Int {
        max((trend.points.map(\.tokens).max() ?? 0) * 6 / 5, 1)
    }

    private func chinese(_ value: Int?) -> String {
        value.map(TokenCountFormatter.chinese) ?? "--"
    }

    private func spokenDetail(_ value: Int?) -> String? {
        value.map(TokenCountFormatter.accessibility)
    }
}

private struct OtherAccountsSection: View {
    let profiles: [AccountProfile]
    let currentProfile: String?
    let clientDisplayName: String
    let switchStage: AccountSwitchStage?
    let switchingDisabled: Bool
    let onSwitch: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle("其他账号", detail: profiles.isEmpty ? "没有其他可切换账号" : "\(profiles.count) 个")
            if profiles.isEmpty {
                GroupedPanel {
                    Text("当前没有其他已配置账号。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(WorkbenchSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                GroupedPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(profiles.enumerated()),
                            id: \.element.id
                        ) { index, profile in
                            OtherAccountRow(
                                profile: profile,
                                clientDisplayName: clientDisplayName,
                                switchStage: switchStage,
                                switchingDisabled: switchingDisabled,
                                onSwitch: { onSwitch(profile.name) }
                            )
                            if index < profiles.count - 1 {
                                Divider().padding(.leading, WorkbenchSpacing.md)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct OtherAccountRow: View {
    let profile: AccountProfile
    let clientDisplayName: String
    let switchStage: AccountSwitchStage?
    let switchingDisabled: Bool
    let onSwitch: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalRow
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                accountIdentity
                HStack(spacing: WorkbenchSpacing.md) {
                    accountValues
                }
                switchButton
            }
            .padding(WorkbenchSpacing.md)
        }
    }

    private var horizontalRow: some View {
        HStack(spacing: WorkbenchSpacing.md) {
            accountIdentity
            accountValues
            switchButton
        }
        .padding(WorkbenchSpacing.md)
    }

    private var accountIdentity: some View {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AccountPresentationBuilder.profileDisplayName(profile.name))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(profile.name)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
    }

    @ViewBuilder
    private var accountValues: some View {
        Group {
                CompactAccountValue(
                    title: quotaTitle(profile.rateLimits.primary, fallback: "主要"),
                    value: quota(profile.rateLimits.primary)
                )
                CompactAccountValue(
                    title: quotaTitle(profile.rateLimits.secondary, fallback: "其他"),
                    value: quota(profile.rateLimits.secondary)
                )
                CompactAccountValue(title: "重置卡", value: resetCount)
        }
    }

    private var switchButton: some View {
                Button(action: onSwitch) {
                    if switchStage?.profile == profile.name {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text(stageText)
                        }
                    } else {
                        Text("切换并重启 \(clientDisplayName)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(switchingDisabled || switchStage != nil)
                .frame(width: 132)
                .accessibilityRepresentation {
                    Button(
                        "切换到 \(AccountPresentationBuilder.profileDisplayName(profile.name)) 并重启 \(clientDisplayName)",
                        action: onSwitch
                    )
                    .disabled(switchingDisabled || switchStage != nil)
                    .accessibilityHint("结束当前 \(clientDisplayName) 进程，切换登录账号后重新启动")
    }
    }

    private func quota(_ window: AccountQuotaWindow?) -> String {
        window?.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "--"
    }

    private var resetCount: String {
        (
            profile.resetCreditDetails?.availableCount
                ?? profile.rateLimits.resetCredits?.availableCount
                ?? profile.rateLimits.creditsAvailable
        ).map(String.init) ?? "--"
    }

    private func quotaTitle(_ window: AccountQuotaWindow?, fallback: String) -> String {
        AccountPresentationBuilder.quotaWindowName(minutes: window?.windowMinutes) ?? fallback
    }

    private var stageText: String {
        switch switchStage {
        case .switching: "切换中"
        case .verifying: "核对中"
        case nil: ""
        }
    }
}

private struct AccountRolesSection: View {
    let roles: AccountRolesPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle("账号角色", detail: "三种来源独立")
            GroupedPanel {
                VStack(alignment: .leading, spacing: 0) {
                    roleRow(roles.desktop, systemImage: "person.crop.circle")
                    Divider().padding(.leading, 42)
                    roleRow(
                        roles.task,
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    Divider().padding(.leading, 42)
                    roleRow(roles.attribution, systemImage: "chart.bar.xaxis")
                }
            }
        }
    }

    private func roleRow(
        _ role: AccountRoleRowPresentation,
        systemImage: String
    ) -> some View {
        AdaptiveLabelValueRow {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title)
                        .font(
                            .system(
                                size: WorkbenchInterfaceContract.bodySize,
                                weight: .medium
                            )
                        )
                    Text(role.source)
                        .font(
                            .system(size: WorkbenchInterfaceContract.microSize)
                        )
                        .foregroundStyle(.tertiary)
                }
            }
        } trailing: {
            HStack(spacing: WorkbenchSpacing.xs) {
                Text(role.profileDisplayName)
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.captionSize,
                            weight: .medium
                        )
                    )
                StatusChip(
                    role.confidence.displayName,
                    color: role.confidence == .inferred
                        ? .orange
                        : .secondary
                )
            }
        }
    }
}

private struct AccountStorageSection: View {
    let presentation: AccountStoragePresentation
    let clientIsRunning: Bool
    let legacyProfileSwitcherRunning: Bool
    let isMigrating: Bool
    let onMigrate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle("账号数据")
            GroupedPanel {
                AdaptiveLabelValueRow {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(presentation.title)
                                .font(
                                    .system(
                                        size: WorkbenchInterfaceContract.bodySize,
                                        weight: .medium
                                    )
                                )
                            Text(presentation.detail)
                                .font(
                                    .system(
                                        size: WorkbenchInterfaceContract.microSize
                                    )
                                )
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if presentation.canMigrateLegacyProfiles
                                && (clientIsRunning || legacyProfileSwitcherRunning)
                            {
                                Text(migrationBlockMessage)
                                    .font(
                                        .system(
                                            size: WorkbenchInterfaceContract.microSize
                                        )
                                    )
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } trailing: {
                    if presentation.canMigrateLegacyProfiles {
                        Button {
                            onMigrate()
                        } label: {
                            if isMigrating {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在检查")
                                }
                            } else {
                                Text("迁移旧 Profiles…")
                            }
                        }
                        .controlSize(.small)
                        .disabled(
                            clientIsRunning
                                || legacyProfileSwitcherRunning
                                || isMigrating
                        )
                        .help("迁移后旧目录仍会保留")
                    }
                }
            }
        }
    }

    private var migrationBlockMessage: String {
        if legacyProfileSwitcherRunning {
            return "先退出旧 Profile Switcher，才能执行迁移。"
        }
        return "先退出当前桌面客户端，才能执行迁移。"
    }
}

private struct CompactAccountValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .frame(width: 58, alignment: .leading)
    }
}

private struct AccountDiagnosticsSection: View {
    let payload: AccountDashboardPayload?
    let onOpen: () -> Void

    var body: some View {
        DisclosureGroup("技术来源与诊断") {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                if let status = payload?.desktopStatus {
                    HStack {
                        Text("账号接管")
                        Spacer()
                        Text(status.message ?? status.state)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("官方 App Server 只读验证登录状态与额度；账号库存储和切换由本机 Codex Home 中的工作台数据负责。")
                    .foregroundStyle(.tertiary)
                HStack {
                    Spacer()
                    Button("打开诊断与修复") { onOpen() }
                        .accessibilityHint("检查桌面客户端、Codex Home、账号来源和内置后端")
                }
            }
            .font(.system(size: 10))
            .padding(.top, WorkbenchSpacing.xs)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(WorkbenchSpacing.md)
        .background(
            Color.workbenchCard,
            in: RoundedRectangle(cornerRadius: WorkbenchRadius.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WorkbenchRadius.panel)
                .stroke(Color.workbenchBorder.opacity(0.72), lineWidth: 0.5)
        )
    }
}

private struct DiagnosticLine: View {
    let title: String
    let role: AccountRole

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(role.profile.map(AccountPresentationBuilder.profileDisplayName) ?? "未知")
                .foregroundStyle(.secondary)
            StatusChip(role.confidence.displayName, color: role.confidence.color)
        }
    }
}

private struct AccountNotice: View {
    let title: String
    let message: String
    let color: Color
    let systemImage: String

    var body: some View {
        SurfaceCard {
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
