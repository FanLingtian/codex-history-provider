# Codex Local History Layout

Use this reference when inspecting or repairing local Codex conversation visibility after provider switches.

## Important Paths

Codex home is usually one of:

- `$env:CODEX_HOME`
- `$HOME/.codex`
- `%USERPROFILE%\.codex`

Important files and directories:

- `config.toml` - current Codex configuration, including current `model_provider`.
- `state_5.sqlite` - desktop app state database; conversation rows live in `threads`.
- `sessions/` - active rollout JSONL files.
- `archived_sessions/` - archived rollout JSONL files.
- `session_index.jsonl` - session index used by clients.
- `.codex-global-state.json` - desktop app global state.

## SQLite Schema

The relevant table is `threads`.

Important columns:

- `id` - thread/session id.
- `rollout_path` - path to the rollout JSONL file.
- `model_provider` - provider bucket used by Codex UI filtering.
- `archived` - `0` for normal list, `1` for archived.
- `title` - visible thread title.
- `updated_at_ms` - recent ordering signal in newer databases.

Typical inspection query:

```sql
SELECT model_provider, archived, COUNT(*)
FROM threads
GROUP BY model_provider, archived
ORDER BY model_provider, archived;
```

Migration query:

```sql
UPDATE threads SET model_provider = '<target-provider>';
```

Source-filtered migration query:

```sql
UPDATE threads
SET model_provider = '<target-provider>'
WHERE model_provider = '<source-provider>';
```

Always create a SQLite backup before migration or rollback:

```powershell
sqlite3 state_5.sqlite ".backup '<backup-path>'"
```

## JSONL Metadata

Rollout files are JSONL. The first line usually contains `session_meta`:

```json
{"type":"session_meta","payload":{"model_provider":"rightcode"}}
```

Repair by replacing all exact JSON properties matching:

```text
"model_provider":"..."
```

with:

```text
"model_provider":"<target-provider>"
```

For source-filtered migration, replace only exact source markers matching:

```text
"model_provider":"<source-provider>"
```

Some files may be locked while Codex App is open. First check whether each locked conversation is in the migration scope by comparing its SQLite `model_provider` with the requested migration. A source-filtered migration only needs locked conversations whose current provider equals the source provider. An all-provider migration only needs locked conversations whose current provider differs from the target provider.

When a locked JSONL file is outside the migration scope, ignore the lock. When a locked JSONL file does need migration, do not update the matching SQLite row. Match locked files to `threads.rollout_path`; if they cannot be matched safely, report that uncertainty and tell the user to quit Codex fully and rerun the migration. This keeps each locked conversation in a consistent pre-migration state instead of changing SQLite while leaving JSONL unchanged.

## Backup Manifest

The bundled script writes `manifest.json` in each backup directory.

Use it for rollback instead of guessing which files were changed. The manifest records:

- script version
- Codex home
- source provider, when migration was source-filtered
- target provider
- SQLite provider distribution before and after
- JSONL provider distribution before and after
- changed JSONL relative paths
- locked JSONL relative paths
- backup file names

Rollback restores the SQLite backup and only JSONL files listed as changed by the migration.

Cleanup deletes a migration backup directory only after explicit user confirmation. Once cleanup runs, that migration's rollback point is gone.
