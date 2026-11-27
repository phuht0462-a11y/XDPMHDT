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
    [switch]$VerifyOnly,
    [switch]$SelfTest
)

# PowerShell 5.1 can wrap a JSON array inside another Object[].
# Recursively flatten media URL lists to avoid passing Object[] into [Uri].
function Expand-MediaUrls {
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) { $Value.Trim() }
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        foreach ($nested in $Value) { Expand-MediaUrls -Value $nested }
    }
}

if ($SelfTest) {
    $one = @(Expand-MediaUrls -Value (ConvertFrom-Json -InputObject '["http://localhost:8080/a.jpg"]'))
    $two = @(Expand-MediaUrls -Value @(@((ConvertFrom-Json -InputObject '["http://localhost:8080/a.jpg","http://localhost:8080/b.jpg"]'))))
    if ($one.Count -ne 1 -or $two.Count -ne 2 -or
        $one[0] -ne 'http://localhost:8080/a.jpg' -or
        $two[0] -notmatch '^http://' -or $two[1] -notmatch '^http://') {
        throw 'URL array flattening self-test FAILED.'
    }
    Write-Host 'URL array flattening self-test PASSED.' -ForegroundColor Green
    return
}

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

$referencedUrls = @()
try {
    $artifactResult = Invoke-RestMethod -Uri "$Gateway/api/artifacts" -TimeoutSec 15
    $artifacts = @($artifactResult.data)
    Write-Host "Artifacts in live database: $($artifacts.Count)"
    if ($artifacts.Count -ne 6) {
        Write-Warning 'Demo seed expects 6 artifacts. Existing MySQL volume may predate 09_demo_seed.sql; do not reset it.'
    }
    foreach ($artifact in $artifacts) {
        $id = $artifact.id
        if ($null -eq $id) {
            Write-Warning 'An artifact in /api/artifacts has no id; skipping detail check.'
            continue
        }
        try {
            $vi = Invoke-RestMethod -Uri "$Gateway/api/artifacts/$($id)?lang=vi" -TimeoutSec 15
            $en = Invoke-RestMethod -Uri "$Gateway/api/artifacts/$($id)?lang=en" -TimeoutSec 15
            $viText = [bool]$vi.data.content
            $enText = [bool]$en.data.content
            $enAudio = -not [string]::IsNullOrWhiteSpace([string]$en.data.content.audioUrl)
            Write-Host "Artifact $($id): vi text=$viText, en text=$enText, en audio URL=$enAudio, en fallback=$($en.data.fallback)"
            foreach ($detail in @($vi.data, $en.data)) {
                if (-not $detail) { continue }
                if ($detail.thumbnailUrl) { $referencedUrls += [string]$detail.thumbnailUrl }
                if ($detail.content) {
                    if ($detail.content.audioUrl) { $referencedUrls += [string]$detail.content.audioUrl }
                    if ($detail.content.videoUrl) { $referencedUrls += [string]$detail.content.videoUrl }
                    $rawImages = $detail.content.imageUrls
                    if ($rawImages -is [string] -and $rawImages.Trim().StartsWith('[')) {
                        try {
                            # ConvertFrom-Json may return an Object[] even for one image.
                            # Append each URL string rather than a nested array.
                            $decodedImages = ConvertFrom-Json -InputObject $rawImages
                            foreach ($image in (Expand-MediaUrls -Value $decodedImages)) {
                                $referencedUrls += [string]$image
                            }
                        }
                        catch { $failed += "Artifact $($id): invalid imageUrls JSON" }
                    } elseif ($rawImages -is [array]) {
                        foreach ($image in (Expand-MediaUrls -Value $rawImages)) {
                            $referencedUrls += [string]$image
                        }
                    } elseif ($rawImages -is [string] -and -not [string]::IsNullOrWhiteSpace($rawImages)) {
                        $referencedUrls += $rawImages
                    }
                }
                foreach ($asset in @($detail.media)) {
                    if ($asset -and $asset.fileUrl) { $referencedUrls += [string]$asset.fileUrl }
                }
            }
        } catch {
            Write-Warning "Artifact $($id): cannot check translations ($($_.Exception.Message))"
        }
    }
    Write-Host 'Note: checked-in demo includes EN audio only. VI audio is not part of the supplied seed.'
} catch {
    Write-Warning "Cannot read /api/artifacts: $($_.Exception.Message)"
}

# Recursively normalize even legacy nested Object[] values before HEAD checks.
$liveUrls = @($referencedUrls | ForEach-Object { Expand-MediaUrls -Value $_ } | Sort-Object -Unique)
Write-Host "Verifying media URLs referenced by live database: $($liveUrls.Count)"
foreach ($url in $liveUrls) {
    try {
        $uri = [Uri]$url
        if ($uri.Scheme -notin @('http', 'https')) { throw 'URL scheme is not http(s)' }
        $response = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 15
        if ($response.StatusCode -ne 200) {
            $failed += "DB URL HTTP $($response.StatusCode): $url"
        }
    } catch {
        $failed += "DB URL unreachable: $url ($($_.Exception.Message))"
    }
}

if ($failed.Count -gt 0) {
    Write-Warning 'Missing or inaccessible media URLs:'
    foreach ($failure in $failed) { Write-Warning $failure }
    throw "Media validation FAILED ($($failed.Count) files). Check the Gateway, container upload directory and existing database URL references."
}

Write-Host 'Media restore and HTTP verification PASSED.' -ForegroundColor Green
