# --- scan_missing_audio.ps1 (V51 - Stable) ---
# Finds files with zero audio streams ("no audio tracks").
# FIX: Uses Get-JsonProp for safe property access.
# FIX: Auto-loads target folders from user settings if no path provided.
# FIX: Wraps Sort-Object results in @() to prevent Strict Mode .Count crashes.

param(
    [string]$ScanPath = "", # Leave empty to use Batch User Settings
    [string]$LogFile = "missing_audio_report.csv",
    [switch]$NoPause = $false
)

Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

# --- 1) DETERMINE REPORT FILE ---
$LogPath = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }

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
$Cols = @("Date","FullPath","Size_MB","Status","Detail")
$results = [System.Collections.Generic.List[object]]::new()

Write-Host "Analyzing $($allFiles.Count) files..." -ForegroundColor Cyan

foreach ($file in $allFiles) {
    $sizeMB = [math]::Round($file.Length / 1MB, 2)
    
    # We ask only for audio streams to speed up probing
    $info = Invoke-FfprobeJson $file.FullName @("-show_streams","-select_streams","a")
    
    if (-not $info) {
        $results.Add([pscustomobject]@{
            Date=(Get-Date).ToString('yyyy-MM-dd HH:mm')
            FullPath=$file.FullName
            Size_MB=$sizeMB
            Status="ProbeError"
            Detail="ffprobe exit=$($Global:LastFfprobeExitCode)"
        })
        continue
    }

    # Strict-Safe stream checking using common helper
    $streams = Get-JsonProp $info "streams"
    $count = if ($streams) { @($streams).Count } else { 0 }

    if ($count -eq 0) {
        # Double check: did we miss it because of stream selection? 
        # Probe everything just to be sure it's truly silent.
        $fullInfo = Invoke-FfprobeJson $file.FullName @("-show_streams")
        $fullStreams = Get-JsonProp $fullInfo "streams"
        
        $audioCount = 0
        if ($fullStreams) {
            foreach ($s in $fullStreams) {
                if ($s.codec_type -eq "audio") { $audioCount++ }
            }
        }

        if ($audioCount -eq 0) {
            Write-Host " [NO AUDIO] $($file.Name)" -ForegroundColor Red
            $results.Add([pscustomobject]@{
                Date=(Get-Date).ToString('yyyy-MM-dd HH:mm')
                FullPath=$file.FullName
                Size_MB=$sizeMB
                Status="MISSING_AUDIO"
                Detail="Audio streams: 0"
            })
        }
    }
}

# FIX: Wrap Sort-Object in @() to guarantee an Array, so .Count never fails
$sorted = @($results | Sort-Object FullPath)

if ($sorted.Count -gt 0) {
    $sorted | Select-Object $Cols | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
    Write-Host "Found $($sorted.Count) silent files. Report saved to: $LogPath" -ForegroundColor Red
} else {
    Write-Host "Clean scan. All files have audio." -ForegroundColor Green
}

if (-not $NoPause) { Pause }