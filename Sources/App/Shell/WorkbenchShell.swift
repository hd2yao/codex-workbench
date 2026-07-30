import CodexWorkbenchCore
import SwiftUI

struct WorkbenchShell: View {
    @ObservedObject var model: WorkbenchAppModel
    @AppStorage(WorkbenchAppearancePreference.defaultsKey)
    private var appearanceRawValue = WorkbenchAppearancePreference.system.rawValue

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: WorkbenchLayout.sidebarMinimum,
                    ideal: WorkbenchLayout.sidebarIdeal,
                    max: WorkbenchLayout.sidebarMaximum
                )
        } detail: {
            detail
                .background(Color.workbenchWindow)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                TargetClientChip(
                    target: model.desktopClientTarget,
                    selectionStatus: model.desktopClientSelection.status,
                    unavailableReason: model.desktopClientUnavailableReason
                )
                .help(model.desktopClientIdentityDetail)

                Button {
                    CodexIntegrationService.openDesktopClient(
                        model.desktopClientTarget
                    )
                } label: {
                    Label(
                        model.desktopClientOpenLabel,
                        systemImage: "rectangle.on.rectangle"
                    )
                }
                .disabled(model.desktopClientTarget == nil)
                .help(model.desktopClientIdentityDetail)

                Menu {
                    ForEach(WorkbenchAppearancePreference.allCases, id: \.self) { preference in
                        Button {
                            appearanceRawValue = preference.rawValue
                            WorkbenchThemeController.apply(preference)
                        } label: {
                            HStack {
                                Label(preference.title, systemImage: preference.systemImage)
                                if selectedAppearance == preference {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("外观", systemImage: "circle.lefthalf.filled")
                }
                .help("外观：\(selectedAppearance.title)")
                .accessibilityLabel("切换工作台外观，当前为\(selectedAppearance.title)")

                Button {
                    Task { await model.refreshAll(refreshResetCredits: model.selectedModule == .accounts) }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing || model.isVisualAcceptanceMode)
                .help("刷新操作日志与账号状态")
                .accessibilityRepresentation {
                    Button("刷新工作台数据") {
                        Task {
                            await model.refreshAll(
                                refreshResetCredits: model.selectedModule == .accounts
                            )
                        }
                    }
                    .disabled(model.isRefreshing || model.isVisualAcceptanceMode)
                }
            }
        }
    }

    private var selectedAppearance: WorkbenchAppearancePreference {
        WorkbenchAppearancePreference.persisted(appearanceRawValue)
    }

    private var sidebar: some View {
        List(selection: $model.selectedModule) {
            Section {
                ForEach(AppModule.allCases, id: \.self) { module in
                    Label(module.title, systemImage: module.systemImage)
                        .tag(module)
                }
            } header: {
                Text("工作台")
            }

        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarBrandHeader()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Divider()
                DataHealthIndicator(
                    presentation: model.dataHealthPresentation
                )
                Text("\(model.events.count) 条跨任务事件")
                    .font(
                        .system(size: WorkbenchInterfaceContract.microSize)
                    )
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, WorkbenchSpacing.sm)
            .padding(.vertical, WorkbenchSpacing.sm)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedModule ?? .overview {
        case .overview:
            OverviewView(model: model)
        case .activity:
            ActivityView(model: model)
        case .accounts:
            AccountsView(model: model)
        case .projects:
            ProjectsView(model: model)
        case .toolsAndSkills:
            ToolsSkillsView(model: model)
        case .projectServices:
            ProjectServicesView(model: model)
        }
    }
}

private struct TargetClientChip: View {
    let target: DesktopClientTarget?
    let selectionStatus: DesktopClientSelectionStatus
    let unavailableReason: String?

    private var color: Color {
        guard selectionStatus == .selected else { return .orange }
        return target?.isRunning == true ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(target?.displayName ?? "客户端有歧义")
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.microSize,
                            weight: .semibold
                        )
                    )
                Text(processText)
                    .font(
                        .system(
                            size: WorkbenchInterfaceContract.microSize,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Color.workbenchCard,
            in: RoundedRectangle(
                cornerRadius: WorkbenchRadius.chip,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: WorkbenchRadius.chip,
                style: .continuous
            )
            .stroke(Color.workbenchHairline, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var processText: String {
        if let processIdentifier = target?.processIdentifier {
            return "PID \(processIdentifier)"
        }
        return target == nil ? "不可操作" : "未运行"
    }

    private var accessibilityText: String {
        guard let target else {
            return unavailableReason ?? "桌面客户端不可操作"
        }
        return "\(target.displayName)，\(processText)，\(target.selectionReason.displayName)"
    }
}
