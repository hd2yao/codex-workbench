# Codex 工作台独立仓库与模块化迁移 Spec

## 背景和目标

Codex 工作台已经从单一的 Codex Profile Switcher 演变为包含账号与额度、操作日志、项目与任务、项目服务、工具与自动化及外观控制的 macOS 工作台。它不应继续作为 `agent-tools` 中的一个小工具，也不应把账号能力误当成其余功能的父级。

本次将工作台迁移到独立、公开的 GitHub 仓库 `codex-workbench`，以产品模块为源码边界；原 Profile Switcher 中仍由工作台依赖的本地数据逻辑同步迁入，新仓库不再提供独立 Profile Switcher App。

## 用户场景

1. 用户访问一个公开仓库即可获取、构建和运行完整的 Codex 工作台。
2. 维护者新增“操作日志”或“项目服务”时，可以在与“账号”并列的模块目录中工作，而不是放进笼统的集成目录。
3. 从源码安装的用户仍可以读取本机 Codex/ChatGPT 登录、日志、项目、任务、工作环境和自动化信息；已有 profile 数据不迁移、不删除。
4. 原 `agent-tools` 仓库不再携带工作台源码、独立 Profile Switcher 源码或它们的本地构建产物。

## 范围

- 创建个人 GitHub 公开仓库 `codex-workbench`，默认分支为 `main`，首次发布包含当前已验证的工作台源码和本次架构文档。
- 新仓库采用以下产品模块布局：
  - `Modules/Accounts`：账号识别、账号切换、官方额度、客户端重启。
  - `Modules/ActivityLedger`：操作日志、生命周期 Hook、事件读取与筛选。
  - `Modules/ProjectsAndTasks`：项目、任务、线程 Token 归因、风险、上下文接续。
  - `Modules/ProjectServices`：工作目录、Git、端口和本地服务。
  - `Modules/ToolsAndAutomation`：Skills、工作流、Hook 与自动化规则。
  - `Modules/Appearance`：工作台外观；ChatGPT 皮肤功能只保留现有源码，不扩展功能。
  - `Modules/Overview`：仅组合上述模块的摘要，不拥有独立数据源。
- 使用 `Platform/DesktopClientRuntime` 承担 ChatGPT/Codex 客户端探测、启动和重启，使用 `Platform/LocalDataRuntime` 承担共享本地数据辅助程序；这两个目录不是产品模块。
- 迁入仍被工作台使用的 Python 后端源和相应单元测试，取消其对相邻 `codex-profile-switcher` 目录的构建依赖。
- 更新构建、安装、发布保护和测试脚本，使其仅使用新仓库内的文件。
- 在新仓库 `main` 可用后，删除 `hd2yao/agent-tools` 中经审计确认属于历史 Codex Profile Switcher 的 12 个 GitHub Release；保留 Git tag，避免改写历史提交。
- 在验证新仓库可构建、测试和安装迁移检查通过后，从 `agent-tools` 主分支删除 `codex-workbench/`、`codex-profile-switcher/` 及仅服务于它们的忽略构建产物；保留水提醒和线程桥接工具。

## 非目标

- 不发布新的 DMG 或 GitHub Release，不删除 Git tag；本次只移除旧仓库中已经确认属于独立 Profile Switcher 的历史 Release。
- 不删除或改写 `~/.codex`、`~/.codex-profiles`、操作日志、Hook 配置或已安装的 Codex Workbench App。
- 不新增账号、模型供应商、ChatGPT 皮肤或 K3 设计功能。
- 不改变当前 Apple Silicon/macOS 13+ 发行边界，也不处理 Developer ID 签名或公证。
- 不把与工作台无关的 `water-reminder`、`codex-thread-bridge` 迁入新仓库。

## 验收标准

- AC-001：`https://github.com/hd2yao/codex-workbench` 为公开仓库，`main` 含完整源代码、文档、测试和有效 `origin`。
- AC-002：新仓库的源码按已批准的产品模块和平台层组织，且不含 `integrations` 作为兜底目录，也不含独立 Profile Switcher UI/App。
- AC-003：`Package.swift`、构建和安装脚本在新仓库内定位所有所需源码；`build-account-backend.sh` 不再引用仓库外 `../codex-profile-switcher`。
- AC-004：Swift 单元测试、UI 源码契约测试、源码安装检查和本地后端构建检查在新仓库中通过；若因未安装的外部签名/发布工具无法执行，必须明确记录并不冒充通过。
- AC-005：新仓库的 README 解释产品模块、从源码安装方式、本地数据与隐私边界，以及签名/公证在源码运行时不是前置条件。
- AC-006：`agent-tools` 的 `main` 不再跟踪工作台或旧 Profile Switcher 源码，保留不相关工具；其本机构建缓存被安全删除，不影响用户的 `~/.codex*` 数据或已安装 App。
- AC-007：现有账号、日志、项目、项目服务、工具与自动化页面仍存在于模块对应目录，且账户、操作日志、项目与任务、项目服务、工具与自动化均为并列的一级产品模块。
- AC-008：`hd2yao/agent-tools` 中的 12 个历史 Codex Profile Switcher GitHub Release 已删除，Git tag 未删除，新的 `codex-workbench` 仓库未创建 Release。

## 约束和假设

- GitHub CLI 已以 `hd2yao` 认证；若认证或新仓库名称冲突，停止远端创建并报告实际原因。
- 用户明确授权创建公开仓库、推送代码、迁移并删除 `agent-tools` 中的指定源码及其本机构建产物。
- 发布截图是评审材料，不是“已发布版本”，会随源码迁入；`.build/`、`build/`、临时 DMG/ZIP 为本地产物，先以忽略规则和实际路径确认后删除。
- 为降低迁移回归风险，现有 Swift 类型和公开行为不改名；本次首先按目录归属整理，名称清理可作为后续小任务。

## 待确认问题

无阻断问题。新仓库名称和可见性已由用户指定为 `codex-workbench`、公开。
