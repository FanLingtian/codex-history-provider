param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("inspect", "migrate", "rollback", "cleanup")]
  [string]$Action,

  [string]$Provider,
  [string]$FromProvider,
  [string]$CodexHome,
  [string]$BackupDir,
  [switch]$RestoreConfig
)

$ErrorActionPreference = "Stop"
$ScriptVersion = "1.4.0"

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Write-Info {
  param([string]$Message)
  Write-Host "    $Message"
}

function Quote-PowerShellArgument {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Quote-SqlLiteral {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Quote-SqliteDotPath {
  param([string]$Path)
  return "'" + ($Path -replace "'", "''") + "'"
}

function Resolve-CodexHome {
  param([string]$Requested)

  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($Requested)) {
    $candidates.Add($Requested) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    $candidates.Add($env:CODEX_HOME) | Out-Null
    $candidates.Add((Join-Path $env:CODEX_HOME ".codex")) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($HOME)) {
    $candidates.Add((Join-Path $HOME ".codex")) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $candidates.Add((Join-Path $env:USERPROFILE ".codex")) | Out-Null
  }

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }
    try {
      $full = [System.IO.Path]::GetFullPath($candidate)
    } catch {
      continue
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
      return $full
    }
  }

  throw "Could not locate Codex home. Pass -CodexHome explicitly."
}

function Get-CodexPaths {
  param([string]$CodexHomePath)

  return [pscustomobject]@{
    Home = $CodexHomePath
    Config = Join-Path $CodexHomePath "config.toml"
    StateDb = Join-Path $CodexHomePath "state_5.sqlite"
    SessionIndex = Join-Path $CodexHomePath "session_index.jsonl"
    GlobalState = Join-Path $CodexHomePath ".codex-global-state.json"
    Sessions = Join-Path $CodexHomePath "sessions"
    ArchivedSessions = Join-Path $CodexHomePath "archived_sessions"
    BackupRoot = Join-Path $CodexHomePath "history-provider-backups"
  }
}

function Require-Sqlite {
  $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
  if (-not $cmd) {
    throw "sqlite3 was not found in PATH. Install sqlite3 or add it to PATH before using this skill."
  }
  return $cmd.Source
}

function Invoke-Sqlite {
  param(
    [string]$Database,
    [string]$Sql
  )

  $output = & sqlite3 $Database $Sql
  if ($LASTEXITCODE -ne 0) {
    throw "sqlite3 failed for database: $Database"
  }
  return $output
}

function Get-ConfigProvider {
  param([string]$ConfigPath)

  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return $null
  }

  $text = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
  if ($text -match '(?m)^model_provider\s*=\s*"([^"]+)"') {
    return $matches[1]
  }
  return $null
}

function Get-SqliteDistribution {
  param([string]$StateDbPath)

  if (-not (Test-Path -LiteralPath $StateDbPath)) {
    return @()
  }
  return @(Invoke-Sqlite -Database $StateDbPath -Sql "SELECT model_provider || '|' || archived || '|' || COUNT(*) FROM threads GROUP BY model_provider, archived ORDER BY model_provider, archived;")
}

function Test-SqliteColumn {
  param(
    [string]$StateDbPath,
    [string]$Table,
    [string]$Column
  )

  $columns = @(Invoke-Sqlite -Database $StateDbPath -Sql "PRAGMA table_info($Table);")
  foreach ($line in $columns) {
    $parts = $line -split '\|'
    if ($parts.Count -ge 2 -and $parts[1] -eq $Column) {
      return $true
    }
  }
  return $false
}

function Get-SessionJsonlFiles {
  param($Paths)

  $files = New-Object System.Collections.Generic.List[string]
  foreach ($dir in @($Paths.Sessions, $Paths.ArchivedSessions)) {
    if ([System.IO.Directory]::Exists($dir)) {
      [System.IO.Directory]::EnumerateFiles($dir, "*.jsonl", [System.IO.SearchOption]::AllDirectories) | ForEach-Object {
        $files.Add($_) | Out-Null
      }
    }
  }
  return $files
}

function Get-RelativeCodexPath {
  param(
    [string]$CodexHome,
    [string]$Path
  )

  $homeFull = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\', '/')
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  if ($pathFull.StartsWith($homeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $pathFull.Substring($homeFull.Length).TrimStart('\', '/')
  }
  return [System.IO.Path]::GetFileName($Path)
}

function Get-SqliteRolloutPathVariants {
  param(
    $Paths,
    [string]$Path
  )

  $variants = New-Object System.Collections.Generic.List[string]
  $full = [System.IO.Path]::GetFullPath($Path)
  $relative = Get-RelativeCodexPath -CodexHome $Paths.Home -Path $full
  foreach ($candidate in @($full, $relative, ($full -replace '\\', '/'), ($relative -replace '\\', '/'))) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $variants.Contains($candidate)) {
      $variants.Add($candidate) | Out-Null
    }
  }
  return @($variants)
}

function Join-SqlStringList {
  param([string[]]$Values)

  return (($Values | ForEach-Object { Quote-SqlLiteral $_ }) -join ",")
}

function Convert-RolloutPathToFullPath {
  param(
    $Paths,
    [string]$RolloutPath
  )

  if ([string]::IsNullOrWhiteSpace($RolloutPath)) {
    return $null
  }

  $candidate = $RolloutPath
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $Paths.Home $candidate
  }

  try {
    return [System.IO.Path]::GetFullPath($candidate)
  } catch {
    return $null
  }
}

function Get-SqliteThreadRows {
  param($Paths)

  if (-not (Test-SqliteColumn -StateDbPath $Paths.StateDb -Table "threads" -Column "rollout_path")) {
    throw "Locked JSONL files were found, but threads.rollout_path is missing. Refusing migration because locked conversations cannot be checked atomically."
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $lines = @(Invoke-Sqlite -Database $Paths.StateDb -Sql "SELECT id || char(31) || model_provider || char(31) || COALESCE(rollout_path, '') FROM threads;")
  foreach ($line in $lines) {
    $parts = $line -split [string]([char]31), 3
    if ($parts.Count -lt 3) {
      continue
    }
    $rows.Add([pscustomobject]@{
      Id = $parts[0]
      Provider = $parts[1]
      RolloutPath = $parts[2]
      FullPath = Convert-RolloutPathToFullPath -Paths $Paths -RolloutPath $parts[2]
    }) | Out-Null
  }
  return $rows.ToArray()
}

function Get-LockedJsonlMigrationPlan {
  param(
    $Paths,
    [string[]]$LockedJsonl,
    [string]$Provider,
    [string]$FromProvider
  )

  $needsMigration = New-Object System.Collections.Generic.List[object]
  $ignored = New-Object System.Collections.Generic.List[object]
  $unmatched = New-Object System.Collections.Generic.List[object]
  if ($LockedJsonl.Count -eq 0) {
    return [pscustomobject]@{
      NeedsMigration = @()
      Ignored = @()
      Unmatched = @()
    }
  }

  $threadRows = Get-SqliteThreadRows -Paths $Paths
  foreach ($file in $LockedJsonl) {
    $full = [System.IO.Path]::GetFullPath($file)
    $relative = Get-RelativeCodexPath -CodexHome $Paths.Home -Path $file
    $matches = @($threadRows | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_.FullPath) -and
      [string]::Equals($_.FullPath, $full, [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($matches.Count -eq 0) {
      $unmatched.Add([pscustomobject]@{
        File = $file
        Relative = $relative
        Matches = @()
        RolloutPaths = @()
      }) | Out-Null
      continue
    }

    $matchingRowsThatNeedMigration = @($matches | Where-Object {
      if ([string]::IsNullOrWhiteSpace($FromProvider)) {
        $_.Provider -ne $Provider
      } else {
        $_.Provider -eq $FromProvider
      }
    })
    $item = [pscustomobject]@{
      File = $file
      Relative = $relative
      Matches = @($matches)
      RolloutPaths = @($matchingRowsThatNeedMigration | ForEach-Object { $_.RolloutPath })
      Providers = @($matches | ForEach-Object { $_.Provider } | Sort-Object -Unique)
    }
    if ($matchingRowsThatNeedMigration.Count -gt 0) {
      $needsMigration.Add($item) | Out-Null
    } else {
      $ignored.Add($item) | Out-Null
    }
  }

  return [pscustomobject]@{
    NeedsMigration = $needsMigration.ToArray()
    Ignored = $ignored.ToArray()
    Unmatched = $unmatched.ToArray()
  }
}

function Get-LockedRolloutPathSqlList {
  param(
    [object[]]$LockedItems
  )

  $values = New-Object System.Collections.Generic.List[string]
  foreach ($item in $LockedItems) {
    foreach ($rolloutPath in @($item.RolloutPaths)) {
      if (-not [string]::IsNullOrWhiteSpace($rolloutPath) -and -not $values.Contains($rolloutPath)) {
        $values.Add($rolloutPath) | Out-Null
      }
    }
  }
  return (Join-SqlStringList @($values))
}

function New-StringSet {
  param([string[]]$Values)

  $set = @{}
  foreach ($value in $Values) {
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $set[$value] = $true
    }
  }
  return $set
}

function Format-MigrationRerunCommand {
  param(
    $Paths,
    [string]$Provider,
    [string]$FromProvider
  )

  $command = "powershell -NoProfile -ExecutionPolicy Bypass -File " + (Quote-PowerShellArgument $PSCommandPath) + " -Action migrate -CodexHome " + (Quote-PowerShellArgument $Paths.Home)
  if (-not [string]::IsNullOrWhiteSpace($FromProvider)) {
    $command += " -FromProvider " + (Quote-PowerShellArgument $FromProvider)
  }
  $command += " -Provider " + (Quote-PowerShellArgument $Provider)
  return $command
}

function Get-JsonlDistribution {
  param($Paths)

  $counts = @{}
  $locked = New-Object System.Collections.Generic.List[string]
  foreach ($file in Get-SessionJsonlFiles -Paths $Paths) {
    try {
      $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
      foreach ($match in [regex]::Matches($text, '"model_provider":"([^"]+)"')) {
        $provider = $match.Groups[1].Value
        if (-not $counts.ContainsKey($provider)) {
          $counts[$provider] = 0
        }
        $counts[$provider]++
      }
    } catch {
      $locked.Add($file) | Out-Null
    }
  }

  return [pscustomobject]@{
    Counts = $counts
    Locked = @($locked)
  }
}

function Convert-HashtableToLines {
  param([hashtable]$Table)

  if (-not $Table -or $Table.Count -eq 0) {
    return @()
  }
  return @($Table.Keys | Sort-Object | ForEach-Object { "$_=$($Table[$_])" })
}

function Copy-IfExists {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (Test-Path -LiteralPath $Source) {
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
  }
}

function New-MigrationBackup {
  param(
    $Paths,
    [string]$Provider,
    [string]$FromProvider,
    [string[]]$SqliteBefore,
    [hashtable]$JsonlBefore
  )

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backupDir = Join-Path $Paths.BackupRoot $stamp
  $jsonlBackupDir = Join-Path $backupDir "session-jsonl"
  New-Item -ItemType Directory -Path $jsonlBackupDir -Force | Out-Null

  Copy-IfExists -Source $Paths.Config -Destination (Join-Path $backupDir "config.toml")
  Copy-IfExists -Source $Paths.SessionIndex -Destination (Join-Path $backupDir "session_index.jsonl")
  Copy-IfExists -Source $Paths.GlobalState -Destination (Join-Path $backupDir ".codex-global-state.json")

  $quotedBackupDb = Quote-SqliteDotPath (Join-Path $backupDir "state_5.sqlite")
  $null = Invoke-Sqlite -Database $Paths.StateDb -Sql ".backup $quotedBackupDb"

  return [pscustomobject]@{
    BackupDir = $backupDir
    JsonlBackupDir = $jsonlBackupDir
    ManifestPath = Join-Path $backupDir "manifest.json"
    Manifest = [ordered]@{
      version = $ScriptVersion
      created_at = (Get-Date).ToString("o")
      action = "migrate"
      codex_home = $Paths.Home
      source_provider = $FromProvider
      target_provider = $Provider
      sqlite_distribution_before = @($SqliteBefore)
      jsonl_distribution_before = @(Convert-HashtableToLines $JsonlBefore)
      files = [ordered]@{
        state_db_backup = "state_5.sqlite"
        config_backup = "config.toml"
        session_index_backup = "session_index.jsonl"
        global_state_backup = ".codex-global-state.json"
        jsonl_backup_dir = "session-jsonl"
      }
      changed_jsonl = @()
      locked_jsonl = @()
      sqlite_distribution_after = @()
      jsonl_distribution_after = @()
    }
  }
}

function Save-Manifest {
  param(
    [string]$Path,
    $Manifest
  )

  $json = $Manifest | ConvertTo-Json -Depth 8
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Show-Distribution {
  param(
    [string]$Title,
    [string[]]$SqliteLines,
    [hashtable]$JsonlCounts
  )

  Write-Step $Title
  Write-Host "SQLite threads:"
  if ($SqliteLines.Count -eq 0) {
    Write-Host "  (none)"
  } else {
    foreach ($line in $SqliteLines) {
      Write-Host "  $line"
    }
  }

  Write-Host "JSONL markers:"
  $jsonLines = Convert-HashtableToLines $JsonlCounts
  if ($jsonLines.Count -eq 0) {
    Write-Host "  (none)"
  } else {
    foreach ($line in $jsonLines) {
      Write-Host "  $line"
    }
  }
}

function Invoke-Inspect {
  param($Paths)

  $sqlitePath = Require-Sqlite
  $configProvider = Get-ConfigProvider -ConfigPath $Paths.Config
  $sqliteDist = Get-SqliteDistribution -StateDbPath $Paths.StateDb
  $jsonlDist = Get-JsonlDistribution -Paths $Paths

  Write-Step "Inspect Codex history provider state"
  Write-Info "CodexHome: $($Paths.Home)"
  Write-Info "sqlite3: $sqlitePath"
  Write-Info "config provider: $(if ($configProvider) { $configProvider } else { '(not found)' })"
  Show-Distribution -Title "Provider distribution" -SqliteLines $sqliteDist -JsonlCounts $jsonlDist.Counts

  if ($jsonlDist.Locked.Count -gt 0) {
    Write-Step "Locked or unreadable JSONL files"
    foreach ($path in $jsonlDist.Locked) {
      Write-Host "  $path"
    }
  }
}

function Invoke-Migrate {
  param(
    $Paths,
    [string]$Provider,
    [string]$FromProvider
  )

  if ([string]::IsNullOrWhiteSpace($Provider)) {
    throw "-Provider is required for -Action migrate."
  }
  if ($Provider -match '[\r\n]') {
    throw "Provider must be a single-line value."
  }
  if (-not [string]::IsNullOrWhiteSpace($FromProvider) -and $FromProvider -match '[\r\n]') {
    throw "FromProvider must be a single-line value."
  }
  if (-not (Test-Path -LiteralPath $Paths.StateDb)) {
    throw "Missing state database: $($Paths.StateDb)"
  }

  $null = Require-Sqlite
  $sqliteBefore = Get-SqliteDistribution -StateDbPath $Paths.StateDb
  $jsonBefore = Get-JsonlDistribution -Paths $Paths
  $lockedPlan = Get-LockedJsonlMigrationPlan -Paths $Paths -LockedJsonl $jsonBefore.Locked -Provider $Provider -FromProvider $FromProvider
  $backup = New-MigrationBackup -Paths $Paths -Provider $Provider -FromProvider $FromProvider -SqliteBefore $sqliteBefore -JsonlBefore $jsonBefore.Counts

  Write-Step "Migrating SQLite threads.model_provider"
  $providerSql = Quote-SqlLiteral $Provider
  $whereClauses = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($FromProvider)) {
    $fromProviderSql = Quote-SqlLiteral $FromProvider
    $whereClauses.Add("model_provider=$fromProviderSql") | Out-Null
  }
  if ($lockedPlan.NeedsMigration.Count -gt 0) {
    $lockedSqlList = Get-LockedRolloutPathSqlList -LockedItems $lockedPlan.NeedsMigration
    $whereClauses.Add("(rollout_path IS NULL OR rollout_path NOT IN ($lockedSqlList))") | Out-Null
  }

  $updateSql = "UPDATE threads SET model_provider=$providerSql"
  if ($whereClauses.Count -gt 0) {
    $updateSql += " WHERE " + (@($whereClauses) -join " AND ")
  }
  $updateSql += ";"
  $null = Invoke-Sqlite -Database $Paths.StateDb -Sql $updateSql

  $rerunCommand = Format-MigrationRerunCommand -Paths $Paths -Provider $Provider -FromProvider $FromProvider
  if ($lockedPlan.NeedsMigration.Count -gt 0) {
    Write-Step "Locked JSONL files excluded from migration"
    Write-Info "SQLite rows with matching rollout_path were not updated, so those conversations remain consistent with their locked JSONL files."
    Write-Info "These conversations may remain under their previous provider until Codex App is fully quit and the same migration is rerun."
    Write-Info "rerun command after quitting Codex App:"
    Write-Host "  $rerunCommand"
    foreach ($item in $lockedPlan.NeedsMigration) {
      Write-Host "  locked: $($item.Relative) [providers: $(@($item.Providers) -join ', ')]"
    }
  }
  if ($lockedPlan.Unmatched.Count -gt 0) {
    Write-Step "Locked JSONL files not matched to SQLite threads"
    Write-Info "No matching SQLite row was found for these files, so no SQLite row was excluded for them."
    Write-Info "If these files should be part of the migration, fully quit Codex App and rerun:"
    Write-Host "  $rerunCommand"
    foreach ($item in $lockedPlan.Unmatched) {
      Write-Host "  locked unmatched: $($item.Relative)"
    }
  }

  Write-Step "Migrating session JSONL model_provider markers"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $changed = New-Object System.Collections.Generic.List[string]
  $locked = New-Object System.Collections.Generic.List[string]
  $prelockedSkippedRelatives = New-StringSet -Values @(@($lockedPlan.NeedsMigration + $lockedPlan.Unmatched) | ForEach-Object { $_.Relative })
  $prelockedIgnoredRelatives = New-StringSet -Values @($lockedPlan.Ignored | ForEach-Object { $_.Relative })
  $jsonlPattern = '"model_provider":"[^"]+"'
  if (-not [string]::IsNullOrWhiteSpace($FromProvider)) {
    $jsonlPattern = '"model_provider":"' + [regex]::Escape($FromProvider) + '"'
  }

  foreach ($file in Get-SessionJsonlFiles -Paths $Paths) {
    $relative = Get-RelativeCodexPath -CodexHome $Paths.Home -Path $file
    if ($prelockedSkippedRelatives.ContainsKey($relative)) {
      $locked.Add($relative) | Out-Null
      continue
    }
    if ($prelockedIgnoredRelatives.ContainsKey($relative)) {
      continue
    }
    try {
      $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
      $newText = [regex]::Replace($text, $jsonlPattern, ('"model_provider":"' + $Provider + '"'))
      if ($newText -ne $text) {
        $backupPath = Join-Path $backup.JsonlBackupDir $relative
        Copy-IfExists -Source $file -Destination $backupPath
        [System.IO.File]::WriteAllText($file, $newText, $utf8NoBom)
        $changed.Add($relative) | Out-Null
      }
    } catch {
      $locked.Add($relative) | Out-Null
    }
  }

  $sqliteAfter = Get-SqliteDistribution -StateDbPath $Paths.StateDb
  $jsonAfter = Get-JsonlDistribution -Paths $Paths
  $backup.Manifest.changed_jsonl = @($changed)
  $backup.Manifest.locked_jsonl = @($locked)
  $backup.Manifest.sqlite_distribution_after = @($sqliteAfter)
  $backup.Manifest.jsonl_distribution_after = @(Convert-HashtableToLines $jsonAfter.Counts)
  Save-Manifest -Path $backup.ManifestPath -Manifest $backup.Manifest

  Show-Distribution -Title "Provider distribution after migration" -SqliteLines $sqliteAfter -JsonlCounts $jsonAfter.Counts
  Write-Step "Migration summary"
  Write-Info "source provider: $(if ([string]::IsNullOrWhiteSpace($FromProvider)) { '(all)' } else { $FromProvider })"
  Write-Info "target provider: $Provider"
  Write-Info "backup dir: $($backup.BackupDir)"
  Write-Info "updated JSONL files: $($changed.Count)"
  Write-Info "locked/skipped JSONL files: $($locked.Count)"
  if ($lockedPlan.Ignored.Count -gt 0) {
    Write-Info "ignored locked JSONL files already outside migration scope: $($lockedPlan.Ignored.Count)"
  }
  foreach ($item in $locked) {
    Write-Host "  locked: $item"
  }
}

function Invoke-Rollback {
  param(
    [string]$RequestedCodexHome,
    [string]$BackupDir,
    [switch]$RestoreConfig
  )

  if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    throw "-BackupDir is required for -Action rollback."
  }

  $manifestPath = Join-Path $BackupDir "manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing manifest.json in backup directory: $BackupDir"
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $rollbackHome = $RequestedCodexHome
  if ([string]::IsNullOrWhiteSpace($rollbackHome)) {
    $rollbackHome = [string]$manifest.codex_home
  }
  $rollbackHome = Resolve-CodexHome -Requested $rollbackHome
  $paths = Get-CodexPaths -CodexHomePath $rollbackHome
  $null = Require-Sqlite

  $backupState = Join-Path $BackupDir "state_5.sqlite"
  if (-not (Test-Path -LiteralPath $backupState)) {
    throw "Missing state_5.sqlite backup: $backupState"
  }

  Write-Step "Restoring state_5.sqlite"
  $quotedBackup = Quote-SqliteDotPath $backupState
  $null = Invoke-Sqlite -Database $paths.StateDb -Sql ".restore $quotedBackup"

  Write-Step "Restoring JSONL files changed by migration"
  $locked = New-Object System.Collections.Generic.List[string]
  foreach ($relative in @($manifest.changed_jsonl)) {
    if ([string]::IsNullOrWhiteSpace($relative)) {
      continue
    }
    $source = Join-Path (Join-Path $BackupDir "session-jsonl") $relative
    $dest = Join-Path $paths.Home $relative
    if (-not (Test-Path -LiteralPath $source)) {
      Write-Host "  missing backup JSONL: $relative"
      continue
    }
    try {
      Copy-IfExists -Source $source -Destination $dest
    } catch {
      $locked.Add($relative) | Out-Null
    }
  }

  Copy-IfExists -Source (Join-Path $BackupDir "session_index.jsonl") -Destination $paths.SessionIndex
  Copy-IfExists -Source (Join-Path $BackupDir ".codex-global-state.json") -Destination $paths.GlobalState
  if ($RestoreConfig) {
    Copy-IfExists -Source (Join-Path $BackupDir "config.toml") -Destination $paths.Config
  }

  $sqliteAfter = Get-SqliteDistribution -StateDbPath $paths.StateDb
  $jsonAfter = Get-JsonlDistribution -Paths $paths
  Show-Distribution -Title "Provider distribution after rollback" -SqliteLines $sqliteAfter -JsonlCounts $jsonAfter.Counts

  Write-Step "Rollback summary"
  Write-Info "backup dir: $BackupDir"
  Write-Info "restored config: $($RestoreConfig.IsPresent)"
  Write-Info "locked/skipped JSONL files: $($locked.Count)"
  foreach ($item in $locked) {
    Write-Host "  locked: $item"
  }
}

function Invoke-CleanupBackup {
  param([string]$BackupDir)

  if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    throw "-BackupDir is required for -Action cleanup."
  }

  $backupFull = [System.IO.Path]::GetFullPath($BackupDir).TrimEnd('\', '/')
  $manifestPath = Join-Path $backupFull "manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing manifest.json in backup directory: $backupFull"
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$manifest.action -ne "migrate") {
    throw "Refusing to clean backup because manifest action is not migrate: $backupFull"
  }
  if ([string]::IsNullOrWhiteSpace([string]$manifest.codex_home)) {
    throw "Refusing to clean backup because manifest is missing codex_home: $backupFull"
  }

  $backupRoot = [System.IO.Path]::GetFullPath((Join-Path ([string]$manifest.codex_home) "history-provider-backups")).TrimEnd('\', '/')
  $backupRootPrefix = $backupRoot + [System.IO.Path]::DirectorySeparatorChar
  if (-not $backupFull.StartsWith($backupRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean backup outside expected backup root: $backupFull"
  }

  Write-Step "Cleaning migration backup"
  Remove-Item -LiteralPath $backupFull -Recurse -Force
  Write-Info "deleted backup dir: $backupFull"
}

if ($Action -eq "cleanup") {
  Invoke-CleanupBackup -BackupDir $BackupDir
  exit 0
}

if ($Action -eq "rollback") {
  Invoke-Rollback -RequestedCodexHome $CodexHome -BackupDir $BackupDir -RestoreConfig:$RestoreConfig
  exit 0
}

$resolvedHome = Resolve-CodexHome -Requested $CodexHome
$paths = Get-CodexPaths -CodexHomePath $resolvedHome

switch ($Action) {
  "inspect" { Invoke-Inspect -Paths $paths }
  "migrate" { Invoke-Migrate -Paths $paths -Provider $Provider -FromProvider $FromProvider }
}
