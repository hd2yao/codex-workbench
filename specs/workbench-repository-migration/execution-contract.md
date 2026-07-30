# Codex 工作台独立仓库与模块化迁移执行契约

## Intent Lock

- 本次只将完整工作台作为独立公开仓库落地，并将源码从旧工具集合剥离。
- 产品模块一律并列；账号、操作日志、项目与任务、项目服务、工具与自动化均不得降级为某个账号“集成”。

## Scope Fence

- 范围内：仓库创建、文件迁移、Swift Package 路径调整、Python 后端内聚、测试/构建脚本修正、README/架构文档、旧源码和确定的本地产物清理、提交与推送，以及删除经审计确认的旧 Profile Switcher GitHub Release。
- 范围外：新功能设计、账户数据迁移、模型供应商接入、App 签名公证、创建新的远端 Release、删除 Git tag、无关工具迁移。

## Approved Behavior

- `Platform` 只能容纳跨模块基础设施；不得成为业务逻辑的兜底目录。
- `Modules` 下每个目录必须对应一项用户可见的工作台能力。
- 旧 Profile Switcher 的 Python 逻辑作为工作台本地数据运行时的一部分迁入；旧菜单栏 Swift UI、旧 Web UI、旧安装/构建脚本不迁入。
- 旧远端 Release 仅在新仓库 `main` 已推送后删除；删除前复核其名称、说明和无资产状态，且不带 `--cleanup-tag`。
- 新仓库在完成迁移和验证前，不删除旧仓库的 tracked 源码；删除后仍可通过 Git 历史恢复。

## Design Constraints

- 架构：SwiftPM 保持两个产品 target（App/Core）和既有模块 API；目录移动不得改变运行行为。
- 数据：不写入、不提交或删除 `~/.codex`、`~/.codex-profiles`、`~/.config`、日志或凭据。
- 依赖：不引入新运行时依赖；Python 后端仍由现有 PyInstaller 构建流程产生。
- Git：新仓库先建立可恢复的迁移分支，经测试后快进到 `main` 并推送；旧 `agent-tools` 通过独立提交删除，不混入无关改动。
- 安全：先审计将提交的文件、`.gitignore` 和大文件，任何凭据疑似项均停止提交。

## Task Batches

- Batch 1：写入迁移文档、清点来源和目标、创建公开仓库及迁移分支。
- Batch 2：复制可保留源码、按模块组织、修改 Package/脚本/测试、进行结构验证。
- Batch 3：构建与测试、提交并推送新仓库、再清理旧仓库源码和确定的构建缓存、推送旧仓库。

## Test Obligations

- 必须验证：新仓库 Git 状态/远端/可见性；无仓库外 profile-switcher 路径；模块目录清单；Swift 单元测试；UI 源码契约；安装迁移和后端资源检查。
- 边界情况：不提交被忽略的构建产物；迁入源码后 Python 导入路径正常；旧仓库保留水提醒和线程桥接。
- 回归敏感区域：账号切换、ChatGPT/Codex 客户端重启、操作日志 Hook、项目 Token 归因、项目服务。

## Review Gates

- 实现前：确认来源工作树干净，确认用户授权公开创建和删除范围，确认没有未跟踪发布包。
- 实现中：每个批次先检查 diff 和 staged 文件大小；结构测试和脚本引用检查必须先于删除旧源码。
- 实现后：完整测试与 build，检查新旧两个仓库状态、远端和最终 diff；逐条收敛验收标准。

## Rewind Triggers

- 回到 Spec：发现某个现有功能无法映射到批准的产品模块，或目录调整要求改变用户可见行为。
- 回到 Plan/契约：构建发现 Python 后端还依赖旧菜单栏/Web UI，或 SwiftPM 不能支持计划内路径布局。
- 暂停并询问用户：GitHub 身份不是 `hd2yao`、`codex-workbench` 已被他人占用、发现需要提交疑似敏感数据、或删除目标包含非工作台/非构建文件。
