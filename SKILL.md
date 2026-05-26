---
name: codex-history-provider
description: Inspect, migrate, and roll back local Codex conversation history provider markers when switching model providers or tools such as cc-switch makes old chats disappear. Use when Codex needs to diagnose hidden/missing local conversations, align state_5.sqlite threads.model_provider with a target provider, patch session JSONL model_provider metadata, create migration backups, or restore a previous backup.
---

# Codex History Provider

Use this skill for local Codex history visibility problems caused by provider marker drift. The goal is to make existing local conversations visible to a selected provider without modifying provider credentials, cc-switch databases, or provider templates unless the user explicitly asks.

## Workflow

1. Start with inspection.
   - Run `scripts/codex_history_provider.ps1 -Action inspect`.
   - If the user's Codex home is nonstandard, pass `-CodexHome <path>`.
   - Report the current config provider, SQLite provider distribution, JSONL provider distribution, and any missing prerequisites.

2. Confirm the target provider before migration.
   - Provider markers are case-sensitive.
   - Use exactly the provider id the user wants visible, for example `openai`, `rightcode`, `custom`, or `ccswitch`.
   - If the user only wants to move conversations from one existing provider bucket to another, also confirm the exact source provider id.
   - Prefer closing Codex App before migration. If it remains open, locked JSONL files may be skipped.

3. Migrate only local history markers.
   - Run `scripts/codex_history_provider.ps1 -Action migrate -Provider <provider>`.
   - To migrate only conversations currently marked with a specific provider, run `scripts/codex_history_provider.ps1 -Action migrate -FromProvider <source-provider> -Provider <target-provider>`.
   - If `-FromProvider` is omitted, all conversation provider markers are migrated to `-Provider`.
   - Do not edit `config.toml`, `auth.json`, cc-switch databases, API keys, or provider templates.
   - Preserve the script output summary, especially the backup directory and locked file list.

4. Ask whether to clean the migration backup.
   - After a successful migration, ask the user whether to delete the backup directory from that migration.
   - Explain that deleting it removes the rollback point for that migration.
   - If locked/skipped JSONL files were reported, also explain:
     - The script first checks whether each locked conversation is actually in the migration scope.
     - Locked conversations outside the migration scope are ignored and do not need user action.
     - For locked conversations that do need migration, the script excludes matching SQLite `threads.rollout_path` rows from migration, so those conversations are kept consistent instead of being partially migrated.
     - Those locked conversations may remain under their previous provider until Codex App is fully quit and the same migration command is rerun.
     - The user can still choose whether to delete the backup after reviewing this risk.
   - If the user says yes, run `scripts/codex_history_provider.ps1 -Action cleanup -BackupDir <backup-dir>`.
   - If the user says no, keep the backup and end the task.

5. If the user needs to quit Codex App and rerun migration.
   - Give the user the exact migration command printed by the script under `rerun command after quitting Codex App`, or reconstruct it with every argument filled in.
   - Use this form, replacing every placeholder before showing it to the user:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\codex_history_provider.ps1" -Action migrate -CodexHome "<codex-home>" -FromProvider "<source-provider>" -Provider "<target-provider>"
```

   - Omit `-FromProvider "<source-provider>"` only if the original migration was an all-provider migration.
   - If `-CodexHome` was not used originally, still include the detected Codex home in the rerun command so the user does not have to guess.
   - Tell the user to copy the exact command before quitting Codex App, because quitting may close the current Codex session.
   - Step-by-step instructions for the user:
     - Copy the exact rerun command.
     - Fully quit Codex App. On Windows, close the app and also check the system tray; if Codex is still there, choose Quit/Exit.
     - If unsure, open Task Manager and end remaining Codex/Codex App processes.
     - Open PowerShell.
     - Paste the exact rerun command and press Enter.
     - Wait for the script to finish and confirm `locked/skipped JSONL files: 0`, or review any remaining locked files it reports.
     - Reopen Codex App and check that the expected conversations are visible.

6. Roll back from a backup when needed.
   - Run `scripts/codex_history_provider.ps1 -Action rollback -BackupDir <backup-dir>`.
   - By default rollback restores `state_5.sqlite`, JSONL files that were modified during migration, `session_index.jsonl`, and `.codex-global-state.json`.
   - Restore `config.toml` only when the user explicitly wants it by passing `-RestoreConfig`.

## Script

Primary script:

```powershell
scripts/codex_history_provider.ps1 -Action inspect
scripts/codex_history_provider.ps1 -Action migrate -Provider openai
scripts/codex_history_provider.ps1 -Action migrate -FromProvider rightcode -Provider openai
scripts/codex_history_provider.ps1 -Action cleanup -BackupDir "<backup-dir>"
scripts/codex_history_provider.ps1 -Action rollback -BackupDir "<backup-dir>"
```

Codex home detection order:

1. `-CodexHome <path>`
2. `$env:CODEX_HOME`
3. `$HOME\.codex`
4. `$env:USERPROFILE\.codex` on Windows

Backups are created under:

```text
<CodexHome>\history-provider-backups\YYYYMMDD-HHMMSS
```

Each backup includes `manifest.json`. Use the manifest as the source of truth for rollback.

## Safety Rules

- Never run migration without a backup directory being created successfully.
- Never delete a migration backup unless the user explicitly confirms cleanup after seeing the backup directory.
- If locked JSONL files are found, first determine whether their matching SQLite rows are in the migration scope. Ignore locked conversations outside the migration scope.
- If a locked JSONL file does need migration, never modify its matching SQLite `threads` rows; keep the locked conversation's SQLite and JSONL provider markers consistent.
- Never silently ignore a missing `sqlite3`; stop and explain that SQLite backup/update requires it.
- Never assume `openai` and `OpenAI` are equivalent.
- Do not update cc-switch provider templates as part of this skill unless the user separately asks for cc-switch repair.
- When locked JSONL files are reported, tell the user exactly which files were skipped, what risk remains, and how to fully quit Codex App and rerun the same migration.

## Reference

For the local history layout, SQLite table, JSONL marker format, and backup manifest meaning, read `references/codex-history-layout.md`.
