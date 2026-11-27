<#
.SYNOPSIS
  Safely repair the original Smart Heritage demo's example.com media URLs.
.DESCRIPTION
  Default is preview-only. -Apply creates a utf8mb4 mysqldump backup outside
  the Git repository, then applies only known legacy placeholder replacements.
  Does not reset Docker volumes, remove artifacts, or touch other databases.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Infra\seed\repair-legacy-demo-db.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Infra\seed\repair-legacy-demo-db.ps1 -Apply
#>
[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sqlFile = Join-Path $PSScriptRoot 'repair-legacy-demo-db.sql'
$container = 'smart_heritage_mysql'
if (-not (Test-Path -LiteralPath $sqlFile -PathType Leaf)) {
    throw "Migration file not found: $sqlFile"
}

Write-Host 'Migration scope: legacy URLs of KVC-01, BTS-01, DM-01 only.'
Write-Host 'VI: text and images. EN: text, images and WAV. No Vietnamese audio/video in supplied seed.'
Write-Host 'Does not touch Favorites, Visit History, user accounts or upload volume.'
if (-not $Apply) {
    Write-Host 'PREVIEW ONLY. No database changes made.' -ForegroundColor Cyan
    Write-Host 'To apply after checking those artifact codes: rerun with -Apply.'
    Write-Host 'Automatic backup: user profile / SmartHeritageBackups / content_db-before-legacy-fix-*.sql'
    return
}

$running = & docker inspect --format '{{.State.Running}}' $container 2>$null
if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne 'true') {
    throw "Container $container is not running. Start Docker Compose first."
}
$backupDir = Join-Path $env:USERPROFILE 'SmartHeritageBackups'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$remoteBackup = "/tmp/sh-content-before-legacy-fix-$stamp.sql"
$backupFile = Join-Path $backupDir "content_db-before-legacy-fix-$stamp.sql"

Write-Host 'Backing up content_db with mysqldump (preserves Vietnamese UTF-8 bytes)...'
# Dump inside the container and docker cp the binary file. Windows PowerShell
# 5.1 stdout piping can corrupt UTF-8 Vietnamese text in SQL dumps.
$dumpCommand = 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction --default-character-set=utf8mb4 --hex-blob --set-gtid-purged=OFF --databases content_db > ' + $remoteBackup
& docker exec $container sh -c $dumpCommand
if ($LASTEXITCODE -ne 0) {
    throw 'Backup failed. No migration applied. Check MySQL credentials for the existing volume.'
}
$src = $container + ':' + $remoteBackup
& docker cp $src $backupFile
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backupFile)) {
    throw 'Backup could not be copied to Windows. No migration applied.'
}
$backupBytes = (Get-Item -LiteralPath $backupFile).Length
if ($backupBytes -lt 1024) {
    throw "Backup is suspiciously small ($backupBytes bytes). No migration applied."
}
Write-Host "Backup saved: $backupFile ($backupBytes bytes)" -ForegroundColor Green

$remoteSql = "/tmp/sh-legacy-demo-media-$stamp.sql"
$dest = $container + ':' + $remoteSql
& docker cp $sqlFile $dest
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to copy SQL into MySQL container. No migration applied.'
}
Write-Host 'Repairing only exact known legacy demo media placeholders...'
$runCommand = 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --default-character-set=utf8mb4 content_db < ' + $remoteSql
& docker exec $container sh -c $runCommand
if ($LASTEXITCODE -ne 0) {
    throw "Migration error. Backup: $backupFile. Inspect error before retrying."
}
Write-Host 'Migration complete; original unrelated content preserved.' -ForegroundColor Green
Write-Host 'Wait ~2 minutes for content-service Redis cache TTL before rechecking API URLs.'
Write-Host 'Then verify with:'
Write-Host '  powershell -ExecutionPolicy Bypass -File Infra\seed\repair-demo-media.ps1 -VerifyOnly'
Write-Host 'If anything remains broken, keep the backup and send warnings; do NOT reset MySQL.'
