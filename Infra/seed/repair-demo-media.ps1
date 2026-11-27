<#
.SYNOPSIS
  Restore and verify Smart Heritage demo images/audio without resetting MySQL.
.DESCRIPTION
  Safe to rerun. Copies only checked-in files to content-service upload volume.
  Does NOT run SQL migrations, delete volumes, restart services, or modify .env.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Infra\seed\repair-demo-media.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Infra\seed\repair-demo-media.ps1 -VerifyOnly
#>
[CmdletBinding()]
param(
    [string]$Gateway = 'http://localhost:8080',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$Gateway = $Gateway.TrimEnd('/')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mediaDir = Join-Path $PSScriptRoot 'media'
$container = 'smart_heritage_content'

if (-not (Test-Path -LiteralPath $mediaDir -PathType Container)) {
    throw "Media folder not found: $mediaDir"
}
$files = @(Get-ChildItem -LiteralPath $mediaDir -File |
    Where-Object { $_.Extension -in @('.jpg', '.jpeg', '.png', '.webp', '.wav', '.mp3', '.ogg', '.m4a') })
$images = @($files | Where-Object { $_.Extension -in @('.jpg', '.jpeg', '.png', '.webp') })
$audio = @($files | Where-Object { $_.Extension -in @('.wav', '.mp3', '.ogg', '.m4a') })
Write-Host "Repo media files: $($files.Count), images: $($images.Count), audio: $($audio.Count)"
if ($files.Count -ne 18 -or $images.Count -ne 12 -or $audio.Count -ne 6) {
    throw "Expected 18 checked-in media assets (12 images + 6 English WAV files). Stop to avoid copying incomplete demo data."
}

if (-not $VerifyOnly) {
    $running = & docker inspect --format '{{.State.Running}}' $container 2>$null
    if ($LASTEXITCODE -ne 0 -or "$running".Trim() -ne 'true') {
        throw "Container $container is not running. Start Docker Compose first; no files were copied."
    }
    Push-Location $repoRoot
    try {
        & docker cp 'Infra/seed/media/.' ($container + ':/app/uploads/')
        if ($LASTEXITCODE -ne 0) {
            throw 'docker cp failed. Do not delete MySQL or Docker volumes.'
        }
        Write-Host "Restored media to $container (upload volume), without changing database." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

$failed = @()
$ok = 0
foreach ($file in $files) {
    $url = "$Gateway/api/media/files/$([Uri]::EscapeDataString($file.Name))"
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 15
        $expectedType = if ($file.Extension -in @('.wav', '.mp3', '.ogg', '.m4a')) { 'audio/' } else { 'image/' }
        $actualType = [string]$response.Headers['Content-Type']
        if ($response.StatusCode -ne 200 -or -not $actualType.StartsWith($expectedType)) {
            $failed += "$($file.Name): HTTP $($response.StatusCode), Content-Type $actualType"
        } else {
            $ok++
        }
    } catch {
        $failed += "$($file.Name): $($_.Exception.Message)"
    }
}
Write-Host "HTTP media verification: $ok/$($files.Count) files OK"

try {
    $langResult = Invoke-RestMethod -Uri "$Gateway/api/languages" -TimeoutSec 15
    $langs = @($langResult.data | Where-Object { $_.active -eq $true })
    Write-Host ("Active language codes: " + (($langs | ForEach-Object { $_.code }) -join ', '))
    if (@($langs | Where-Object { $_.code -eq 'vi' }).Count -eq 0) {
        Write-Warning 'VI language is missing. Inspect content_db.languages.'
    }
    if (@($langs | Where-Object { $_.code -eq 'en' }).Count -eq 0) {
        Write-Warning 'EN language is missing. Inspect content_db.languages.'
    }
} catch {
    Write-Warning "Cannot read /api/languages: $($_.Exception.Message)"
}

try {
    $artifactResult = Invoke-RestMethod -Uri "$Gateway/api/artifacts" -TimeoutSec 15
    $artifacts = @($artifactResult.data)
    Write-Host "Artifacts in live database: $($artifacts.Count)"
    if ($artifacts.Count -ne 6) {
        Write-Warning 'Demo seed expects 6 artifacts. Existing MySQL volume may predate 09_demo_seed.sql; do not reset it.'
    }
    foreach ($id in 1..6) {
        try {
            $vi = Invoke-RestMethod -Uri "$Gateway/api/artifacts/$($id)?lang=vi" -TimeoutSec 15
            $en = Invoke-RestMethod -Uri "$Gateway/api/artifacts/$($id)?lang=en" -TimeoutSec 15
            $viText = [bool]$vi.data.content
            $enText = [bool]$en.data.content
            $enAudio = -not [string]::IsNullOrWhiteSpace([string]$en.data.content.audioUrl)
            Write-Host "Artifact $($id): vi text=$viText, en text=$enText, en audio URL=$enAudio, en fallback=$($en.data.fallback)"
        } catch {
            Write-Warning "Artifact $($id): cannot check translations ($($_.Exception.Message))"
        }
    }
    Write-Host 'Note: checked-in demo includes EN audio only. VI audio is not part of the supplied seed.'
} catch {
    Write-Warning "Cannot read /api/artifacts: $($_.Exception.Message)"
}

if ($failed.Count -gt 0) {
    Write-Warning 'Missing or inaccessible media URLs:'
    foreach ($failure in $failed) { Write-Warning $failure }
    throw "Media validation FAILED ($($failed.Count) files). Check the Gateway, container upload directory and existing database URL references."
}

Write-Host 'Media restore and HTTP verification PASSED.' -ForegroundColor Green
