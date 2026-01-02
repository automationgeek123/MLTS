# --- estimate_savings.ps1 (V37) ---
# Estimates potential savings + rough processing time using ffprobe.
# Fix: uses primary video stream (ignores cover art / attached pictures)

Set-StrictMode -Version Latest

param(
    [string]$ScanPath = ".",
    [int]$MinSavingsMB = 100,
    [string]$ReportFile = "",
    [switch]$NoPause = $false
)

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

$ScanPath = Resolve-ScanPath $ScanPath

# Support file OR directory
$item = Get-Item -LiteralPath $ScanPath -ErrorAction SilentlyContinue
if ($item -is [System.IO.FileInfo]) {
    $files = @($item)
} else {
    $files = Get-ChildItem -LiteralPath $ScanPath -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $Global:ValidExtensions -contains $_.Extension.ToLower() }
}

if (-not $files -or $files.Count -eq 0) {
    Write-Host "No matching files found." -ForegroundColor Yellow
    if (-not $NoPause) { Pause }
    exit
}

$report = [System.Collections.Generic.List[object]]::new()

$totalOldMB = 0.0
$totalEstMB = 0.0
$totalHours = 0.0

foreach ($file in $files) {
    $info = Invoke-FfprobeJson $file.FullName @("-show_format","-show_streams")
    if (-not $info) { continue }

    $v = Get-PrimaryVideoStream $info
    if (-not $v) { continue }

    $duration = TryParse-Double $info.format.duration 0
    if ($duration -le 0) { continue }

    $width = TryParse-Int $v.width 1920
    $codec = [string]$v.codec_name
    $fps = Get-RealFps $v

    # Estimate audio overhead in kbps
    $audioKbps = 0
    $audStreams = $info.streams | Where-Object { $_.codec_type -eq "audio" }
    foreach ($a in $audStreams) {
        $abr = TryParse-Double $a.bit_rate 0
        if ($abr -gt 0) { $audioKbps += [int]($abr / 1000) }
        else {
            $ch = TryParse-Int $a.channels 2
            $audioKbps += (if ($ch -ge 6) { 640 } else { 192 })
        }
    }

    $targetVideoKbps = if ($width -gt 2500) { $Global:MediaConfig.Target4K } else { $Global:MediaConfig.Target1080 }
    $targetTotalKbps = $targetVideoKbps + $audioKbps

    # Estimated new size in MB
    $estMB = ($targetTotalKbps * $duration) / 8 / 1024
    $oldMB = $file.Length / 1MB

    # Skip if already HEVC and not bloated vs estimate
    if ($codec -match '^(hevc|h265)$' -and $oldMB -le ($estMB * 1.15)) { continue }

    $savedMB = $oldMB - $estMB
    if ($savedMB -lt $MinSavingsMB) { continue }

    $speed = if ($width -gt 2500) { [double]$Global:MediaConfig.Speed4K } else { [double]$Global:MediaConfig.Speed1080 }
    if ($speed -le 0) { $speed = 100 }
    $frames = $duration * $fps
    $hours = ($frames / $speed) / 3600

    $totalOldMB += $oldMB
    $totalEstMB += $estMB
    $totalHours += $hours

    $origVideo = Get-VideoSummary -ProbeJson $info -VideoStream $v
    $origAudio = Get-AudioSummary -ProbeJson $info
    $origDV = [int](Test-IsDolbyVision -ProbeJson $info -VideoStream $v)

    $report.Add([pscustomobject]@{
        FullPath = $file.FullName
        Codec    = $codec
        DV       = $origDV
        Video    = $origVideo
        Audio    = $origAudio
        Width    = $width
        Old_GB   = [math]::Round($oldMB / 1024, 2)
        Est_GB   = [math]::Round($estMB / 1024, 2)
        Save_GB  = [math]::Round($savedMB / 1024, 2)
        Hours    = [math]::Round($hours, 2)
    })
}

$sorted = $report | Sort-Object Save_GB -Descending

if ($sorted.Count -gt 0) { $sorted | Select-Object -First 50 | Format-Table -AutoSize }
else { Write-Host "No files exceeded the savings threshold." -ForegroundColor Yellow }

$savingsMB = ($totalOldMB - $totalEstMB)
$savingsGB = $savingsMB / 1024
$savingsTB = $savingsMB / (1024 * 1024)

Write-Host ("Total Savings: {0:N2} GB ({1:N3} TB)" -f $savingsGB, $savingsTB) -ForegroundColor Green
Write-Host ("Est. Processing Time: {0:N1} Hours" -f $totalHours) -ForegroundColor Cyan

if (-not [string]::IsNullOrWhiteSpace($ReportFile)) {
    $outPath = if ([System.IO.Path]::IsPathRooted($ReportFile)) { $ReportFile } else { Join-Path $ScriptDir $ReportFile }
    $sorted | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
    Write-Host "Report written: $outPath" -ForegroundColor Gray
}

if (-not $NoPause) { Pause }
