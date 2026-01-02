# --- scan_missing_audio.ps1 (V37) ---
# Finds files with zero audio streams ("no audio tracks").

Set-StrictMode -Version Latest

param(
    [string]$ScanPath = ".",
    [string]$LogFile = "missing_audio_report.csv",
    [switch]$NoPause = $false
)

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

$ScanPath = Resolve-ScanPath $ScanPath
$LogPath = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }

$Cols = @("Date","FullPath","Size_MB","Status","Detail")

function Write-Row {
    param([string]$FullPath,[double]$Size_MB,[string]$Status,[string]$Detail="")
    [pscustomobject]@{
        Date=(Get-Date).ToString('yyyy-MM-dd HH:mm')
        FullPath=$FullPath
        Size_MB=$Size_MB
        Status=$Status
        Detail=$Detail
    } | Select-Object $Cols | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding UTF8
}

Write-Host "Scanning: $ScanPath" -ForegroundColor Cyan

$item = Get-Item -LiteralPath $ScanPath -ErrorAction SilentlyContinue
if ($item -is [System.IO.FileInfo]) {
    $files = @($item)
} else {
    $files = Get-ChildItem -LiteralPath $ScanPath -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $Global:ValidExtensions -contains $_.Extension.ToLower() }
}

foreach ($file in $files) {
    $sizeMB = [math]::Round($file.Length / 1MB, 2)
    $info = Invoke-FfprobeJson $file.FullName @("-show_streams","-select_streams","a")
    if (-not $info) {
        Write-Row -FullPath $file.FullName -Size_MB $sizeMB -Status "ProbeError" -Detail "ffprobe exit=$($Global:LastFfprobeExitCode)"
        continue
    }
    $count = if ($info.streams) { $info.streams.Count } else { 0 }
    if ($count -eq 0) {
        Write-Host "[NO AUDIO STREAMS] $($file.Name)" -ForegroundColor Red
        Write-Row -FullPath $file.FullName -Size_MB $sizeMB -Status "NoAudioStreams"
    }
}

Write-Host "Done. Report: $LogPath" -ForegroundColor Green
if (-not $NoPause) { Pause }
