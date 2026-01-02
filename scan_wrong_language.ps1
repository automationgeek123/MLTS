# --- scan_wrong_language.ps1 (V37) ---
# Flags files where:
# - No audio track language is in the safe list, OR
# - The default audio track language is not in the safe list

Set-StrictMode -Version Latest

param(
    [string]$ScanPath = ".",
    [string]$LogFile = "wrong_language_report.csv",
    [switch]$StrictUnd = $false,
    [switch]$NoPause = $false
)

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

$ScanPath = Resolve-ScanPath $ScanPath
$LogPath = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }

$safeList = @($Global:MediaConfig.SafeLangs)
if ($StrictUnd) { $safeList = $safeList | Where-Object { $_ -ne "und" } }

$Cols = @("Date","FullPath","Status","DefaultLang","Tracks","Detail")
$results = [System.Collections.Generic.List[object]]::new()

Write-Host "Scanning: $ScanPath" -ForegroundColor Cyan

$item = Get-Item -LiteralPath $ScanPath -ErrorAction SilentlyContinue
if ($item -is [System.IO.FileInfo]) { $files = @($item) }
else {
    $files = Get-ChildItem -LiteralPath $ScanPath -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $Global:ValidExtensions -contains $_.Extension.ToLower() }
}

foreach ($file in $files) {
    $info = Invoke-FfprobeJson $file.FullName @("-show_streams","-select_streams","a")
    if (-not $info) {
        $results.Add([pscustomobject]@{
            Date=(Get-Date).ToString('yyyy-MM-dd HH:mm')
            FullPath=$file.FullName
            Status="ProbeError"
            DefaultLang=""
            Tracks=""
            Detail="ffprobe exit=$($Global:LastFfprobeExitCode)"
        })
        continue
    }

    if (-not $info.streams -or $info.streams.Count -eq 0) { continue }

    $defaultStream = $null
    foreach ($s in $info.streams) {
        if ($s.disposition -and $s.disposition.default -eq 1) { $defaultStream = $s; break }
    }
    if (-not $defaultStream) { $defaultStream = $info.streams[0] }

    $hasSafe = $false
    $trackLog = New-Object 'System.Collections.Generic.List[string]'

    foreach ($s in $info.streams) {
        $langRaw = "und"
        if ($s.tags -and $s.tags.language) { $langRaw = [string]$s.tags.language }
        $lang = Normalize-LanguageTag $langRaw

        if ($safeList -contains $lang) { $hasSafe = $true }

        $suffix = ""
        if ($defaultStream -and $s.index -eq $defaultStream.index) { $suffix = "(default)" }
        $trackLog.Add("$($s.index):$lang$suffix")
    }

    $defaultLangRaw = "und"
    if ($defaultStream.tags -and $defaultStream.tags.language) { $defaultLangRaw = [string]$defaultStream.tags.language }
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

$results | Select-Object $Cols | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
Write-Host "Done. Report: $LogPath" -ForegroundColor Green
if (-not $NoPause) { Pause }
