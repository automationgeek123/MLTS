# --- scan_wrong_language.ps1 (V51 - Strict Sort Fix) ---
# Flags files where languages don't match safe list.
# FIX: Wraps Sort-Object result in @() to prevent single-item crashes.

param(
    [string]$ScanPath = "", # Leave empty to use Batch User Settings
    [string]$LogFile = "wrong_language_report.csv",
    [switch]$StrictUnd = $false,
    [switch]$NoPause = $false
)

Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

$LogPath = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }

# --- TARGETS ---
$targetList = @()
$configTargets = @($Global:MediaConfig.Batch.TargetFolders)

if (-not [string]::IsNullOrWhiteSpace($ScanPath) -and $ScanPath -ne ".") { $targetList += $ScanPath }
elseif ($configTargets.Count -gt 0) { $targetList = $configTargets }
else { $targetList += "." }

# --- GATHER ---
$allFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
Write-Host "Gathering files from $($targetList.Count) folder(s)..." -ForegroundColor Cyan

foreach ($rawPath in $targetList) {
    if (-not (Test-Path $rawPath)) { continue }
    $resolved = Resolve-ScanPath $rawPath
    Write-Host "   > Scanning: $resolved" -ForegroundColor Gray
    
    $item = Get-Item -LiteralPath $resolved -ErrorAction SilentlyContinue
    if ($item -is [System.IO.FileInfo]) { $allFiles.Add($item) } 
    else {
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

# --- ANALYZE ---
$safeList = @($Global:MediaConfig.Media.SafeLangs)
if ($StrictUnd) { $safeList = $safeList | Where-Object { $_ -ne "und" } }

$Cols = @("Date","FullPath","Status","DefaultLang","Tracks","Detail")
$results = [System.Collections.Generic.List[object]]::new()

Write-Host "Analyzing $($allFiles.Count) files..." -ForegroundColor Cyan

foreach ($file in $allFiles) {
    $info = Invoke-FfprobeJson $file.FullName @("-show_streams","-select_streams","a")
    if (-not $info) { continue }

    $streams = @($info.streams)
    if ($streams.Count -eq 0) { continue }

    $defaultStream = $null
    foreach ($s in $streams) {
        if ($s.disposition -and $s.disposition.default -eq 1) { $defaultStream = $s; break }
    }
    if (-not $defaultStream) { $defaultStream = $streams[0] }

    $hasSafe = $false
    $trackLog = New-Object 'System.Collections.Generic.List[string]'

    foreach ($s in $streams) {
        $langRaw = "und"
        $tags = Get-JsonProp $s "tags"
        if ($tags) {
            $l = Get-JsonProp $tags "language"
            if ($l) { $langRaw = [string]$l }
        }
        $lang = Normalize-LanguageTag $langRaw
        if ($safeList -contains $lang) { $hasSafe = $true }

        $suffix = ""
        if ($defaultStream -and $s.index -eq $defaultStream.index) { $suffix = "(default)" }
        $trackLog.Add("$($s.index):$lang$suffix")
    }

    $defaultLangRaw = "und"
    $defTags = Get-JsonProp $defaultStream "tags"
    if ($defTags) {
        $l = Get-JsonProp $defTags "language"
        if ($l) { $defaultLangRaw = [string]$l }
    }
    $defaultLang = Normalize-LanguageTag $defaultLangRaw
    $defaultIsSafe = ($safeList -contains $defaultLang)

    if (-not $hasSafe -or -not $defaultIsSafe) {
        $status = if (-not $hasSafe) { "FOREIGN_ONLY" } else { "DEFAULT_IS_FOREIGN" }
        $results.Add([pscustomobject]@{
            Date=(Get-Date).ToString('yyyy-MM-dd HH:mm')
            FullPath=$file.FullName
            Status=$status
            DefaultLang=$defaultLang
            Tracks=($trackLog -join "|")
            Detail=""
        })
    }
}

# FIX: Force Array for strict safety
$sorted = @($results | Sort-Object FullPath)

if ($sorted.Count -gt 0) {
    $sorted | Select-Object $Cols | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
    Write-Host "Found $($sorted.Count) issues. Report saved to: $LogPath" -ForegroundColor Red
} else {
    Write-Host "Clean scan. No wrong languages found." -ForegroundColor Green
}

if (-not $NoPause) { Pause }