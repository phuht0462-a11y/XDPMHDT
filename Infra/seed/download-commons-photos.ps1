<#
.SYNOPSIS
  Download six heritage photos from Wikimedia Commons for Smart Heritage.
.DESCRIPTION
  Uses verified URLs and credits in commons-heritage-photos.json.
  Downloads to your Downloads folder; never modifies MySQL or Docker.
  Skips existing files by default; use -Force to overwrite.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Infra\seed\download-commons-photos.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $env:USERPROFILE 'Downloads\SmartHeritageCommons'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$manifestPath = Join-Path $PSScriptRoot 'commons-heritage-photos.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest not found: $manifestPath"
}
$photos = @((Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).photos)
if ($photos.Count -ne 6) { throw "Expected six curated photos; found $($photos.Count)." }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$credits = @('# Photo credits for Smart Heritage', '',
    'Keep source, attribution and license with each redistributed photo.', '')
$downloaded = 0
$rateLimited = $false
$failures = @()
# Public project URL identifies the academic downloader.
$userAgent = 'SmartHeritageAcademicDemo/1.1 (https://github.com/phuht0462-a11y/XDPMHDT)'
foreach ($photo in $photos) {
    $name = [string]$photo.file
    if ($name -notmatch '^[A-Za-z0-9_-]+\.jpg$') { throw "Unsafe filename: $name" }
    $uri = [Uri]$photo.imageUrl
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'upload.wikimedia.org') {
        throw "Unexpected image host for $name; allow only upload.wikimedia.org."
    }
    $destination = Join-Path $OutputDir $name
    if ($Force -or -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $tempFile = "$destination.partial"
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
        try {
            Invoke-WebRequest -Uri $uri.AbsoluteUri -UseBasicParsing -OutFile $tempFile -TimeoutSec 90 -UserAgent $userAgent
            if ((Get-Item -LiteralPath $tempFile).Length -lt 10000) {
                throw "File too small or failed download: $name"
            }
            $stream = [IO.File]::OpenRead($tempFile)
            try {
                $a = $stream.ReadByte(); $b = $stream.ReadByte()
                if ($a -ne 255 -or $b -ne 216) {
                    throw "Downloaded file is not JPEG: $name"
                }
            } finally { $stream.Dispose() }
            Move-Item -LiteralPath $tempFile -Destination $destination -Force
            $downloaded++
            Write-Host "Saved $name" -ForegroundColor Green
            # Avoid back-to-back automated requests.
            Start-Sleep -Seconds 4
        } catch {
            if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
            $response = $_.Exception.Response
            $status = if ($null -ne $response) { [int]$response.StatusCode } else { 0 }
            if ($status -eq 429) {
                $retryAfter = if ($null -ne $response) { $response.Headers['Retry-After'] } else { $null }
                Write-Warning "Wikimedia returned HTTP 429 (Too Many Requests) for $name."
                if ($retryAfter) {
                    Write-Warning "Respect Retry-After: $retryAfter"
                } else {
                    Write-Warning 'Do not retry repeatedly. Wait for Wikimedia to lift the rate limit before requesting further photos.'
                }
                $rateLimited = $true
                break
            }
            $failures += "$name : $($_.Exception.Message)"
            Write-Warning "Could not download $name : $($_.Exception.Message)"
        }
    } else {
        Write-Host "Already exists: $name (skipped)"
    }
    $credits += ("## " + $photo.name + " (" + $photo.code + ")")
    $credits += ("- File: " + $name)
    $credits += ("- Author: " + $photo.author)
    $credits += ("- License: " + $photo.license)
    $credits += ("- Source: " + $photo.sourceUrl)
    $credits += ("- Note: " + $photo.note)
    $credits += ''
}
$creditPath = Join-Path $OutputDir 'CREDITS.md'
$credits -join [Environment]::NewLine | Set-Content -LiteralPath $creditPath -Encoding UTF8
Write-Host "Photos ready in: $OutputDir" -ForegroundColor Green
Write-Host "Downloaded now: $downloaded / $($photos.Count); credits: $creditPath"
if ($rateLimited) {
    Write-Warning 'Download stopped after HTTP 429. Existing images remain on disk.'
    Write-Warning 'Continue using the existing 18 local demo media files. Retry the optional Commons batch only when the rate limit has cleared.'
} elseif ($failures.Count -gt 0) {
    Write-Warning "Some optional images could not be downloaded ($($failures.Count))."
    foreach ($failure in $failures) { Write-Warning $failure }
}
Write-Host 'Upload JPEG files in WebAdmin > Artifacts to keep media in project-controlled storage.'
Write-Host 'Do not reset MySQL volumes or depend on remote hotlinks for offline media.'
