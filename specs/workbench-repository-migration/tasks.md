# Codex 工作台独立仓库与模块化迁移任务拆分

- [ ] T001 建立迁移文档、来源清单和结构断言。
  映射：AC-002、AC-007。
  验收：每个现有页面与共享运行时都有目标模块；结构测试会拒绝旧 Profile Switcher UI 和仓库外源码路径。
  验证：运行新增的迁移结构测试。

- [ ] T002 创建公开 `codex-workbench` GitHub 仓库和本地迁移分支。
  映射：AC-001。
  验收：新仓库公开、origin 有效、迁移代码不直接在 `main` 上编辑。
  验证：`gh repo view --json name,url,visibility,defaultBranchRef`、`git status --branch`。

- [ ] T003 迁移当前工作台源码和所需本地数据后端，按产品模块与平台层重组 Swift/Python 文件。
  映射：AC-002、AC-003、AC-007。
  验收：所有现有 Swift 文件与 Python 后端均位于新仓库；旧 Profile Switcher UI、网页和菜单栏脚本不迁入；SwiftPM 与后端构建路径指向新仓库内路径。
  验证：结构测试、`swift package describe`、脚本引用检查。

- [ ] T004 更新 README、安装/构建/测试脚本和 `.gitignore`，将迁移规则落实为可复核说明。
  映射：AC-003、AC-005。
  验收：README 正确描述模块和源码安装；构建产物、凭据和本地数据均不会进入提交。
  验证：README 链接检查、安装迁移检查、`git diff --check`、staged 文件审计。

- [ ] T005 运行完整验证、提交并推送新仓库至 `main`。
  映射：AC-001、AC-004、AC-005。
  验收：所需测试和构建通过，迁移分支快进到 `main`，新仓库公开可见。
  验证：`./test.sh`、`./Tests/Scripts/test-source-bootstrap.sh`、相关脚本测试、`gh repo view`、远端分支审计。

- [ ] T006 从旧 `agent-tools` 删除迁出的工作台/Profile Switcher 源码、确认的本机构建缓存和 12 个历史 Profile Switcher GitHub Release，提交并推送 `main`。
  映射：AC-006、AC-008。
  验收：旧仓库仅保留不相关工具和共用文档；历史 Release 消失而 Git tag 保留；未触碰用户账号/日志/已安装 App 数据。
  验证：`git ls-files` 断言、旧仓库状态/diff、`gh release list`、`git ls-remote --tags` 和 `git push` 输出。
