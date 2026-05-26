# Codex History Provider

[中文](./README.md) | [English](./README.en.md)

一个用于修复 Codex 本地历史记录可见性的 Codex skill。它面向“切换 model provider 后旧对话看不见”的场景，帮助 Codex 检查、迁移和回滚本地历史中的 provider 标记。

这个仓库的主要使用方式是安装为 **Codex skill**，然后让 Codex 按 skill 工作流执行检查或迁移。仓库内的 PowerShell 脚本是 skill 的确定性执行工具，通常不需要用户直接手动运行。

## 解决什么问题

Codex 桌面端的本地历史通常由两层组成：

- `state_5.sqlite`：保存会话索引、标题、归档状态、provider 分组等 UI 状态。
- `sessions/` 和 `archived_sessions/`：保存每个会话的 rollout JSONL。

当你切换 provider、使用自定义 provider、代理 provider 或相关切换工具时，旧对话可能仍然完整保存在本地，但因为 `model_provider` 标记仍属于旧 provider 分组，当前 Codex UI 不再显示它们。

这个 skill 会让 Codex 同时检查 SQLite 和 JSONL 中的 provider 标记，并在迁移前创建备份，避免只改一边造成状态不一致。

## 功能

- 检查当前 Codex 本地历史的 provider 分布。
- 将本地历史迁移到指定目标 provider。
- 只迁移某个来源 provider 到目标 provider。
- 在迁移前创建备份，并支持从备份回滚。
- 识别 Codex App 打开时可能出现的 JSONL 文件锁定。
- 不修改 API key、认证信息、provider 模板或第三方切换工具配置。

## 安装为 Skill

将本仓库克隆到 Codex skills 目录：

```powershell
git clone https://github.com/FanLingtian/codex-history-provider "$env:USERPROFILE\.codex\skills\codex-history-provider"
```

如果已经存在同名目录，请先备份或移除旧目录。安装后，重启或刷新 Codex，让 skill 被重新发现。

## 作为 Skill 使用

在 Codex 中直接提出类似请求即可：

```text
使用 $codex-history-provider 检查我的本地 Codex 历史 provider 状态。
```

```text
使用 $codex-history-provider 将我的本地 Codex 历史迁移到 <target-provider>。
```

```text
使用 $codex-history-provider 只把 <source-provider> 下的历史迁移到 <target-provider>。
```

```text
使用 $codex-history-provider 从备份 <backup-dir> 回滚。
```

`<target-provider>` 和 `<source-provider>` 都必须使用你的 Codex 配置里真实的 provider id，且大小写敏感。

## 依赖

- Windows PowerShell 或 PowerShell。
- `sqlite3` 命令行工具，并且需要在 `PATH` 中可用。
- 已经使用过 Codex App，且存在本地 Codex home，通常是 `%USERPROFILE%\.codex`。

检查 SQLite 依赖：

```powershell
sqlite3 --version
```

## 安全机制

- 每次迁移前都会创建备份目录：

```text
<CodexHome>\history-provider-backups\YYYYMMDD-HHMMSS
```

- 备份包含 SQLite 状态库、变更过的 JSONL 文件、会话索引、桌面端全局状态和 `manifest.json`。
- 如果 JSONL 文件被 Codex App 锁定，skill 会避免只迁移 SQLite 或只迁移 JSONL，尽量保持单个会话的两层元数据一致。
- 回滚时以备份目录中的 `manifest.json` 为准，只恢复该次迁移实际修改过的文件。

## 高级：脚本入口

一般情况下，请优先通过 Codex skill 使用它。若需要审计或手动运行，脚本入口是：

```text
scripts/codex_history_provider.ps1
```

支持的动作包括 `inspect`、`migrate`、`rollback` 和 `cleanup`。手动运行时请先确认目标 provider id，并保留迁移输出中的备份目录。

## License

MIT
