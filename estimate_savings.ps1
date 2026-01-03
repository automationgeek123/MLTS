# --- estimate_savings.ps1 (V55 - Strict Sort Fix) ---
# Estimates potential savings + rough processing time.
# FIX: Wraps Sort-Object result in @() to prevent single-item crashes.

param(
    [string]$ScanPath = "",  # Leave empty to use User Settings
    [int]$MinSavingsMB = 100,
    [string]$ReportFile = "",
    [switch]$NoPause = $false
)

Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

# --- 1) DETERMINE REPORT FILE ---
if ([string]::IsNullOrWhiteSpace($ReportFile)) { 
    $ReportFile = $Global:MediaConfig.Estimate.ReportFile 
}

# --- 2) DETERMINE SCAN TARGETS ---
$targetList = @()
$configTargets = @($Global:MediaConfig.Batch.TargetFolders)

if (-not [string]::IsNullOrWhiteSpace($ScanPath) -and $ScanPath -ne ".") {
    $targetList += $ScanPath
}
elseif ($configTargets.Count -gt 0) {
    $targetList = $configTargets
}
else {
    $targetList += "."
}

# --- 3) GATHER FILES ---
$allFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
Write-Host "Gathering files from $($targetList.Count) folder(s)..." -ForegroundColor Cyan

foreach ($rawPath in $targetList) {
    if (-not (Test-Path $rawPath)) { continue }
    $resolved = Resolve-ScanPath $rawPath
    Write-Host "   > Scanning: $resolved" -ForegroundColor Gray
    
    $item = Get-Item -LiteralPath $resolved -ErrorAction SilentlyContinue
    if ($item -is [System.IO.FileInfo]) {
        $allFiles.Add($item)
    } else {
        $found = Get-ChildItem -LiteralPath $resolved -Recurse -File -ErrorAction SilentlyContinue |
                 Where-Object { $Global:ValidExtensions -contains $_.Extension.ToLower() }
        if ($found) { foreach ($f in $found) { $allFiles.Add($f) } }
    }
}

if ($allFiles.Count -eq 0) {
    Write-Host "No matching files found." -ForegroundColor Yellow
    if (-not $NoPause) { Pause }
    exit
}

# --- 4) ANALYZE ---
$report = [System.Collections.Generic.List[object]]::new()
$totalOldMB = 0.0
$totalEstMB = 0.0
$totalHours = 0.0

Write-Host "Analyzing $($allFiles.Count) files..." -ForegroundColor Cyan

foreach ($file in $allFiles) {
    $info = Invoke-FfprobeJson $file.FullName @("-show_format","-show_streams")
    if (-not $info) { continue }

    $v = Get-PrimaryVideoStream $info
    if (-not $v) { continue }

    $duration = TryParse-Double (Get-JsonProp $info.format "duration") 0
    if ($duration -le 0) { continue }

    $width = TryParse-Int $v.width 0
    $codec = [string]$v.codec_name
    
    # Audio Estimate
    $audioKbps = 0
    if ($info.streams) {
        foreach ($a in $info.streams) {
            if ($a.codec_type -ne "audio") { continue }
            $abr = TryParse-Double (Get-JsonProp $a "bit_rate") 0
            if ($abr -gt 0) { $audioKbps += ($abr / 1000) } 
            else {
                $ch = TryParse-Int (Get-JsonProp $a "channels") 2
                if ($ch -ge 6) { $audioKbps += 640 } else { $audioKbps += 192 }
            }
        }
    }

    # Video Target
    $targetVideoKbps = if ($width -gt 2500) { $Global:MediaConfig.Media.Target4K } else { $Global:MediaConfig.Media.Target1080 }

    # Calc
    $estSizeBits = ($targetVideoKbps + $audioKbps) * 1000 * $duration
    $estMB = $estSizeBits / 8 / 1024 / 1024
    $oldMB = $file.Length / 1MB
    $savedMB = $oldMB - $estMB

    if ($savedMB -lt $MinSavingsMB) { continue }
    if ($codec -match '^(hevc|h265)$' -and $oldMB -le ($estMB * 1.15)) { continue }

    # Time Estimate
    $fps = if ($width -gt 2500) { [double]$Global:MediaConfig.Media.Speed4K } else { [double]$Global:MediaConfig.Media.Speed1080 }
    $frames = $duration * (Get-RealFps $v)
    $hours = $frames / $fps / 3600
    
    $totalHours += $hours
    $totalOldMB += $oldMB
    $totalEstMB += $estMB

    $report.Add([pscustomobject]@{
        FullPath = $file.FullName
        Codec    = $codec
        DV       = [int](Test-IsDolbyVision -j $info -v $v)
        Video    = Get-VideoSummary -j $info -v $v
        Audio    = Get-AudioSummary $info
        Width    = $width
        Old_GB   = [math]::Round($oldMB / 1024, 2)
        Est_GB   = [math]::Round($estMB / 1024, 2)
        Save_GB  = [math]::Round($savedMB / 1024, 2)
        Hours    = [math]::Round($hours, 2)
    })
}

# FIX: Force Array for strict safety
$sorted = @($report | Sort-Object Save_GB -Descending)

if ($sorted.Count -gt 0) { 
    Write-Host "`nTop 30 Candidates (Console Preview):" -ForegroundColor White
    $sorted | Select-Object -First 30 | Format-Table -AutoSize 
    
    if (-not [string]::IsNullOrWhiteSpace($ReportFile)) {
        $fullPath = if ([System.IO.Path]::IsPathRooted($ReportFile)) { $ReportFile } else { Join-Path $ScriptDir $ReportFile }
        $sorted | Export-Csv -Path $fullPath -NoTypeInformation -Encoding UTF8
        Write-Host "Detailed CSV report saved to: $fullPath" -ForegroundColor Green
    }
}
else { 
    Write-Host "No files exceeded the savings threshold ($MinSavingsMB MB)." -ForegroundColor Yellow 
}

$savingsMB = ($totalOldMB - $totalEstMB)
$savingsGB = $savingsMB / 1024
$savingsTB = $savingsMB / (1024 * 1024)

Write-Host ("`nTotal Potential Savings: {0:N2} GB ({1:N3} TB)" -f $savingsGB, $savingsTB) -ForegroundColor Green
Write-Host ("Est. Processing Time: {0:N1} Hours" -f $totalHours) -ForegroundColor Cyan

if (-not $NoPause) { Pause }