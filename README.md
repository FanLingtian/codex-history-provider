# Codex History Provider

[中文](./README.md) | [English](./README.en.md)

**切换 provider 后，让 Codex 历史会话重新可见。**

Codex History Provider 是一个用于修复 Codex 本地历史会话可见性的 **Codex skill**。它面向 Codex Desktop、`/resume` 或 provider 切换后旧会话不可见的场景，帮助 Codex 检查并同步本地会话 metadata 中的 `model_provider` 标记。

关键词：Codex Desktop、Codex skill、历史会话、会话可见性、provider 切换、`model_provider`、rollout JSONL、SQLite、`state_5.sqlite`。

## 解决什么问题

切换 model provider、使用自定义 provider、代理 provider 或 provider 切换工具后，旧会话可能仍然完整保存在本地，但不再出现在 Codex 的历史列表、项目会话列表或 `/resume` 结果里。

这通常不是会话文件丢失，而是这些位置的 provider metadata 不一致：

- `state_5.sqlite` 中的 SQLite 线程表，用于保存会话索引、标题、归档状态、provider 分组等 UI 状态。
- `sessions/` 和 `archived_sessions/` 中的 rollout JSONL 文件，用于保存每个历史会话的事件流和 session metadata。

这个 skill 会让 Codex 同时检查 SQLite 和 rollout JSONL 中的 provider 标记，并在迁移前创建备份，避免只修复一边导致会话 metadata 不一致。

## 适用场景

- 切换 provider 后，旧会话在 Codex Desktop 中不可见。
- `/resume` 或历史列表看不到原本存在的会话。
- 想把某个 provider 分组下的历史会话移动到目标 provider。
- 想先诊断本地会话 metadata 分布，再决定是否迁移。
- 想保留可回滚备份，而不是手动直接修改 SQLite 或 JSONL。

## 功能

- 检查当前 Codex 本地历史会话的 provider 分布。
- 将本地历史会话 metadata 迁移到指定目标 provider。
- 只迁移某个来源 provider 下的历史会话。
- 迁移前创建备份，并支持从备份回滚。
- 识别 Codex App 打开时可能出现的 rollout JSONL 文件锁定。
- 不修改 API key、登录状态、认证文件、provider 模板或第三方切换工具配置。

## 安装为 Skill

将本仓库克隆到 Codex skills 目录：

```powershell
git clone https://github.com/FanLingtian/codex-history-provider "$env:USERPROFILE\.codex\skills\codex-history-provider"
```

如果已经存在同名目录，请先备份或移除旧目录。安装后，重启或刷新 Codex，让 skill 被重新发现。

## 作为 Skill 使用

在 Codex 中直接提出类似请求即可：

```text
使用 $codex-history-provider 检查我的本地 Codex 历史会话 provider 状态。
```

```text
使用 $codex-history-provider 将我的本地 Codex 历史会话迁移到 <target-provider>。
```

```text
使用 $codex-history-provider 只把 <source-provider> 下的历史会话迁移到 <target-provider>。
```

```text
使用 $codex-history-provider 从备份 <backup-dir> 回滚。
```

`<target-provider>` 和 `<source-provider>` 都必须使用你的 Codex 配置里真实的 provider id，且大小写敏感。

## 能力边界

这个 skill 只修复本地历史会话可见性相关的 provider metadata：

- 不修改会话正文、消息内容、标题或历史排序。
- 不修改 `auth.json`、API key、登录状态或 provider 凭据。
- 不修改第三方 provider 切换工具的配置或模板。
- 不尝试重新加密旧会话里的加密内容。
- 如果旧会话本身含有和账号/provider 绑定的加密内容，迁移后通常只能恢复列表可见性，继续对话仍可能受上游加密机制限制。

## 依赖

- Windows PowerShell 或 PowerShell。
- `sqlite3` 命令行工具，并且需要在 `PATH` 中可用。
- 已经使用过 Codex App，且存在本地 Codex home，通常是 `%USERPROFILE%\.codex`。

检查 SQLite 依赖：

```powershell
sqlite3 --version
```

## 安全与回滚

每次迁移前都会创建备份目录：

```text
<CodexHome>\history-provider-backups\YYYYMMDD-HHMMSS
```

备份包含 SQLite 状态库、变更过的 rollout JSONL 文件、会话索引、桌面端全局状态和 `manifest.json`。

处理锁定文件时，skill 会尽量保持单个会话在 SQLite 和 JSONL 两层 metadata 中的一致性。如果某个 rollout JSONL 被 Codex App 锁定，脚本会跳过或排除对应 SQLite 行，并提示完全退出 Codex App 后重试。

回滚时以备份目录中的 `manifest.json` 为准，只恢复该次迁移实际修改过的文件。

## 高级：脚本入口

一般情况下，请优先通过 Codex skill 使用它。若需要审计或手动运行，脚本入口是：

```text
scripts/codex_history_provider.ps1
```

支持的动作包括 `inspect`、`migrate`、`rollback` 和 `cleanup`。手动运行时请先确认目标 provider id，并保留迁移输出中的备份目录。

## License

MIT
