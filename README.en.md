# Codex History Provider

[中文](./README.md) | [English](./README.en.md)

**Make Codex history sessions visible again after switching providers.**

Codex History Provider is a **Codex skill** for repairing local Codex history session visibility. It is designed for cases where older sessions disappear from Codex Desktop, project history, or `/resume` after provider switching, and helps Codex inspect and synchronize local `model_provider` metadata.

Keywords: Codex Desktop, Codex skill, history sessions, session visibility, provider switching, `model_provider`, rollout JSONL, SQLite, `state_5.sqlite`.

## Problem

After switching model providers, using custom providers, proxy providers, or provider-switching tools, older sessions may still exist on disk but no longer appear in Codex history, project session lists, or `/resume` results.

The sessions are often not lost. The usual cause is inconsistent provider metadata across local history surfaces:

- The SQLite threads table in `state_5.sqlite`, which stores the session index, titles, archive state, provider buckets, and other UI state.
- Rollout JSONL files under `sessions/` and `archived_sessions/`, which store each history session's event stream and session metadata.

This skill helps Codex inspect both SQLite and rollout JSONL provider markers and creates a backup before migration, so it does not repair only one side of the session metadata.

## When To Use

- Older sessions are hidden in Codex Desktop after provider switching.
- `/resume` or the history list does not show sessions that still exist locally.
- You want to move history sessions from one provider bucket to a target provider.
- You want to diagnose local session metadata distribution before migrating.
- You want rollback backups instead of manually editing SQLite or JSONL files.

## Features

- Inspect current provider distribution for local Codex history sessions.
- Migrate local history session metadata to a target provider.
- Migrate only sessions under one source provider.
- Create migration backups and support rollback.
- Detect locked rollout JSONL files while Codex App is open.
- Avoid modifying API keys, login state, auth files, provider templates, or third-party provider-switching configuration.

## Install As A Skill

Clone this repository into the Codex skills directory:

```powershell
git clone https://github.com/FanLingtian/codex-history-provider "$env:USERPROFILE\.codex\skills\codex-history-provider"
```

If a directory with the same name already exists, back it up or remove it first. After installation, restart or refresh Codex so the skill can be discovered.

## Use As A Skill

Ask Codex directly, for example:

```text
Use $codex-history-provider to inspect my local Codex history session provider state.
```

```text
Use $codex-history-provider to migrate my local Codex history sessions to <target-provider>.
```

```text
Use $codex-history-provider to migrate only <source-provider> history sessions to <target-provider>.
```

```text
Use $codex-history-provider to roll back from backup <backup-dir>.
```

`<target-provider>` and `<source-provider>` must be real provider ids from your Codex configuration. Provider ids are case-sensitive.

## Boundaries

This skill only repairs provider metadata related to local history session visibility:

- It does not modify message content, session titles, or history ordering.
- It does not modify `auth.json`, API keys, login state, or provider credentials.
- It does not modify configuration or templates from third-party provider-switching tools.
- It does not attempt to re-encrypt encrypted content from older sessions.
- If an older session contains encrypted content tied to a specific account or provider, migration may restore list visibility while continuing or compacting that session can still be limited by upstream encryption behavior.

## Requirements

- Windows PowerShell or PowerShell.
- `sqlite3` available in `PATH`.
- A local Codex home, usually `%USERPROFILE%\.codex`.

Check the SQLite dependency:

```powershell
sqlite3 --version
```

## Safety And Rollback

Every migration creates a backup directory:

```text
<CodexHome>\history-provider-backups\YYYYMMDD-HHMMSS
```

Backups include the SQLite state database, changed rollout JSONL files, session index, desktop global state, and `manifest.json`.

When files are locked, the skill tries to keep each session consistent across both SQLite and JSONL metadata layers. If a rollout JSONL file is locked by Codex App, the script skips or excludes the matching SQLite row and tells you to fully quit Codex App before retrying.

Rollback uses the backup `manifest.json` as the source of truth and restores only files changed by that migration.

## Advanced: Script Entrypoint

Prefer using this repository through the Codex skill workflow. If you need to audit or run the script manually, the script entrypoint is:

```text
scripts/codex_history_provider.ps1
```

Supported actions are `inspect`, `migrate`, `rollback`, and `cleanup`. When running manually, confirm the exact target provider id first and keep the backup directory from the migration output.

## License

MIT
