# Codex History Provider

[中文](./README.md) | [English](./README.en.md)

A Codex skill for repairing local Codex conversation history visibility. It is designed for cases where older conversations become hidden after switching model providers, and helps Codex inspect, migrate, and roll back local history provider markers.

This repository is meant to be used primarily as a **Codex skill**. The bundled PowerShell script is the deterministic execution tool used by the skill; most users should ask Codex to use the skill instead of running the script directly.

## Problem

Codex Desktop local history is usually stored in two layers:

- `state_5.sqlite`: conversation index, titles, archive state, provider buckets, and other UI state.
- `sessions/` and `archived_sessions/`: rollout JSONL files for individual sessions.

When switching providers, using custom providers, proxy providers, or provider-switching tools, older conversations may still exist on disk but become hidden because their `model_provider` marker remains under a previous provider bucket.

This skill helps Codex inspect both SQLite and JSONL provider markers and creates a backup before migration, so it does not repair only one side of the local history metadata.

## Features

- Inspect current local Codex history provider distribution.
- Migrate local history markers to a target provider.
- Migrate only one source provider to a target provider.
- Create migration backups and support rollback.
- Detect locked JSONL files while Codex App is open.
- Avoid modifying API keys, auth files, provider templates, or third-party provider-switching configuration.

## Install As A Skill

Clone this repository into the Codex skills directory:

```powershell
git clone https://github.com/FanLingtian/codex-history-provider "$env:USERPROFILE\.codex\skills\codex-history-provider"
```

If a directory with the same name already exists, back it up or remove it first. After installation, restart or refresh Codex so the skill can be discovered.

## Use As A Skill

Ask Codex directly, for example:

```text
Use $codex-history-provider to inspect my local Codex history provider state.
```

```text
Use $codex-history-provider to migrate my local Codex history to <target-provider>.
```

```text
Use $codex-history-provider to migrate only <source-provider> history to <target-provider>.
```

```text
Use $codex-history-provider to roll back from backup <backup-dir>.
```

`<target-provider>` and `<source-provider>` must be real provider ids from your Codex configuration. Provider ids are case-sensitive.

## Requirements

- Windows PowerShell or PowerShell.
- `sqlite3` available in `PATH`.
- A local Codex home, usually `%USERPROFILE%\.codex`.

Check the SQLite dependency:

```powershell
sqlite3 --version
```

## Safety Model

- Every migration creates a backup directory:

```text
<CodexHome>\history-provider-backups\YYYYMMDD-HHMMSS
```

- Backups include the SQLite state database, changed JSONL files, session index, desktop global state, and `manifest.json`.
- If JSONL files are locked while Codex App is open, the skill avoids migrating only SQLite or only JSONL and keeps each conversation's two metadata layers consistent where possible.
- Rollback uses the backup `manifest.json` as the source of truth and restores only files changed by that migration.

## Advanced: Script Entrypoint

Prefer using this repository through the Codex skill workflow. If you need to audit or run the script manually, the script entrypoint is:

```text
scripts/codex_history_provider.ps1
```

Supported actions are `inspect`, `migrate`, `rollback`, and `cleanup`. When running manually, confirm the exact target provider id first and keep the backup directory from the migration output.

## License

MIT
