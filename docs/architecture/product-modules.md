# 产品模块与源码边界

Codex 工作台是一个完整产品，而不是“账号工具 + 其他集成”。下列模块在产品上并列；`Overview` 只组合信息，不拥有另一套数据源。

| 产品模块 | 用户可见能力 | App 源码 | Core 源码 |
|---|---|---|---|
| 账号与额度 | 本地账号、官方额度、切换与客户端重启 | `Sources/App/Modules/Accounts` | `Sources/Core/Modules/Accounts` |
| 操作日志 | 生命周期事件、筛选、详情和证据 | `Sources/App/Modules/ActivityLedger` | `Sources/Core/Modules/ActivityLedger` |
| 项目与任务 | 工作区、线程、Token 归因、风险与接续 | `Sources/App/Modules/ProjectsAndTasks` | `Sources/Core/Modules/ProjectsAndTasks` |
| 项目环境与服务 | Git、端口、本地服务和工作环境 | `Sources/App/Modules/ProjectServices` | 复用项目与共享数据模型 |
| 工具与自动化 | Skills、规则、Hooks、自动化与资产关系 | `Sources/App/Modules/ToolsAndAutomation` | `Sources/Core/Modules/ToolsAndAutomation` |
| 外观与皮肤 | 工作台浅色、深色和跟随系统偏好 | `Sources/App/Modules/Appearance` | `Sources/Core/Modules/Appearance` |
| 概览 | 组合上述能力的状态摘要 | `Sources/App/Modules/Overview` | 无独立业务数据 |

`Sources/*/Platform` 只放跨模块基础设施。`DesktopClientRuntime` 负责 ChatGPT/Codex 客户端发现、打开和重启；`Platform/LocalDataRuntime` 是随应用构建的 Python 本地数据辅助程序。它们不是产品功能的父级，不能成为业务代码的兜底目录。

旧 Codex Profile Switcher 仅作为历史来源：仍被工作台使用的 Python 数据逻辑已迁入 `Platform/LocalDataRuntime`，旧菜单栏 App、Web 页面和安装脚本不再属于本仓库。
