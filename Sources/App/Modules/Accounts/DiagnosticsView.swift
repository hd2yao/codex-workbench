import CodexWorkbenchCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("诊断与修复")
                        .font(.system(size: 20, weight: .semibold))
                    Text("检查 \(model.desktopClientDisplayName)、Codex Home、账号来源与内置后端；复制内容已自动脱敏。")
                        .font(
                            .system(size: WorkbenchInterfaceContract.microSize)
                        )
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await model.refreshAll(refreshResetCredits: true)
                        model.refreshDiagnostics()
                    }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                        Text("正在刷新")
                    } else {
                        Label("刷新诊断", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing || model.isVisualAcceptanceMode)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(WorkbenchSpacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    GroupedPanel {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(
                                Array(
                                    model.diagnosticSnapshot.findings.enumerated()
                                ),
                                id: \.element.id
                            ) { index, finding in
                                diagnosticFinding(finding)
                                if index
                                    < model.diagnosticSnapshot.findings.count - 1
                                {
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                    }

                    GroupedPanel {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            SectionTitle("当前操作目标")
                            ForEach(
                                model.diagnosticSnapshot.clientIdentityLines,
                                id: \.self
                            ) { line in
                                Text(line)
                                    .font(
                                        .system(
                                            size: WorkbenchInterfaceContract.microSize,
                                            design: .monospaced
                                        )
                                    )
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(WorkbenchSpacing.md)
                    }

                    if !model.diagnosticSnapshot.appSummaries.isEmpty {
                        GroupedPanel {
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                                SectionTitle("已发现的桌面客户端")
                                ForEach(model.diagnosticSnapshot.appSummaries, id: \.self) { summary in
                                    Text(summary)
                                        .font(
                                            .system(
                                                size: WorkbenchInterfaceContract.microSize,
                                                design: .monospaced
                                            )
                                        )
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(WorkbenchSpacing.md)
                        }
                    }
                }
                .padding(WorkbenchSpacing.lg)
            }

            Divider()

            HStack(spacing: WorkbenchSpacing.sm) {
                Button {
                    CodexIntegrationService.openDesktopClient(
                        model.desktopClientTarget
                    )
                } label: {
                    Label(
                        diagnosticOpenLabel,
                        systemImage: "rectangle.on.rectangle"
                    )
                }
                .disabled(model.desktopClientTarget == nil)
                .accessibilityLabel(model.desktopClientOpenLabel)

                Button {
                    model.requestRestartCurrentCodex()
                } label: {
                    if model.accountRestartStage != nil {
                        ProgressView().controlSize(.small)
                        Text("正在重启")
                    } else {
                        Label(
                            diagnosticRestartLabel,
                            systemImage: "arrow.clockwise.circle"
                        )
                    }
                }
                .disabled(
                    model.currentProfileName == nil
                        || model.desktopClientTarget == nil
                        || model.accountRestartStage != nil
                        || model.accountSwitchStage != nil
                        || model.isVisualAcceptanceMode
                )
                .accessibilityLabel(model.desktopClientRestartLabel)

                if model.diagnosticSnapshot.revealTargets.count == 1,
                   let target = model.diagnosticSnapshot.revealTargets.first {
                    Button {
                        CodexIntegrationService.revealDiagnosticTarget(target)
                    } label: {
                        Label("Finder 显示", systemImage: "folder")
                    }
                } else {
                    Menu {
                        ForEach(
                            Array(model.diagnosticSnapshot.revealTargets.enumerated()),
                            id: \.offset
                        ) { _, target in
                            Button(target.label) {
                                CodexIntegrationService.revealDiagnosticTarget(target)
                            }
                        }
                    } label: {
                        Label("Finder 显示", systemImage: "folder")
                    }
                    .disabled(model.diagnosticSnapshot.revealTargets.isEmpty)
                }

                Spacer()

                Button {
                    CodexIntegrationService.copyDiagnosticSummary(model.diagnosticSnapshot)
                } label: {
                    Label("复制脱敏摘要", systemImage: "doc.on.doc")
                }
                .accessibilityHint("复制不含完整路径和认证内容的诊断摘要")
            }
            .padding(WorkbenchSpacing.md)
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 500, idealHeight: 560)
        .background(Color.workbenchWindow)
        .alert(
            "确认\(model.desktopClientRestartLabel)",
            isPresented: restartConfirmationBinding
        ) {
            Button("取消", role: .cancel) {
                model.cancelRestartCurrentCodex()
            }
            Button("仍然重启", role: .destructive) {
                model.confirmRestartCurrentCodex()
            }
        } message: {
            Text(restartConfirmationMessage)
        }
        .accessibilityIdentifier("diagnostics-sheet")
    }

    private func diagnosticFinding(_ finding: DiagnosticFinding) -> some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                Image(systemName: findingSymbol(finding.level))
                    .foregroundStyle(findingColor(finding.level))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(finding.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(finding.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: WorkbenchSpacing.sm)
                StatusChip(finding.level.displayName, color: findingColor(finding.level))
        }
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, 11)
    }

    private var diagnosticOpenLabel: String {
        model.desktopClientTarget == nil
            ? "客户端不可用"
            : model.desktopClientOpenLabel
    }

    private var diagnosticRestartLabel: String {
        model.desktopClientTarget == nil
            ? "无法重启"
            : model.desktopClientRestartLabel
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
            "检测到 \(model.desktopClientDisplayName) 正在运行任务。重启会中断当前任务，确认仍要继续吗？"
        case .waitingTask:
            "检测到待接手任务。重启可能中断尚未完成的状态，确认仍要继续吗？"
        case .unknownState:
            "当前运行状态无法可靠确认。为避免误中断，只有明确确认后才会重启。"
        case nil:
            ""
        }
    }

    private func findingColor(_ level: DiagnosticLevel) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }

    private func findingSymbol(_ level: DiagnosticLevel) -> String {
        switch level {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

private extension DiagnosticLevel {
    var displayName: String {
        switch self {
        case .info: "正常"
        case .warning: "注意"
        case .error: "异常"
        }
    }
}
