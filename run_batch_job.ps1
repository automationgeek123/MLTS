# --- run_batch_job.ps1 (V48) ---
# Controller:
# - Cleans stale hb_temp files
# - Restores .bak ONLY when original is missing
# - Builds per-drive queues
# - Runs shrink_execute.ps1 one file at a time on the most idle drive
# - Writes controller events into the SAME shrink_log.csv schema

Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

$Executor = Join-Path $ScriptDir "shrink_execute.ps1"
$LockFile = Join-Path $ScriptDir "PAUSE.lock"
$LogPath  = Join-Path $ScriptDir "shrink_log.csv"

if (Test-Path -LiteralPath $LockFile) { exit }
if (-not (Test-Path -LiteralPath $Executor)) { throw "Missing shrink_execute.ps1 in: $ScriptDir" }

# Update these folders for your system
$TargetFolders = @(
    "E:\Hindi Movies",
    "G:\English TV",
    "G:\Hindi TV",
    "H:\English Movies"
)

$LogCols = $Global:ShrinkLogColumns

function Write-BatchLog {
    param(
        [string]$InputPath,
        [string]$OutputPath = "-",
        [string]$Strategy = "None",
        [double]$Old_MB = 0,
        [double]$New_MB = 0,
        [double]$Saved_MB = 0,
        [string]$Status,
        [string]$Detail = "",
        [string]$OrigVideo = "",
        [string]$NewVideo  = "",
        [string]$OrigAudio = "",
        [string]$NewAudio  = "",
        [int]$OrigDV = 0,
        [int]$NewDV  = 0,
        [int]$Encode10 = 0,
        [string]$AudioPlan = ""
    )
    [pscustomobject]@{
        Date      = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        InputPath = $InputPath
        OutputPath= $OutputPath
        Strategy  = $Strategy
        Old_MB    = $Old_MB
        New_MB    = $New_MB
        Saved_MB  = $Saved_MB
        Status    = $Status
        Detail    = $Detail
        OrigVideo = $OrigVideo
        NewVideo  = $NewVideo
        OrigAudio = $OrigAudio
        NewAudio  = $NewAudio
        OrigDV    = $OrigDV
        NewDV     = $NewDV
        Encode10  = $Encode10
        AudioPlan = $AudioPlan
    } | Select-Object $LogCols | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding UTF8
}

function Get-DriveIdleStats {
    param([string[]]$DrivesToCheck)
    $stats = @{}
    foreach ($d in $DrivesToCheck) {
        try {
            $ctr = Get-Counter -Counter "\LogicalDisk($d)\% Idle Time" -MaxSamples 2 -ErrorAction Stop
            $avg = ($ctr.CounterSamples.CookedValue | Measure-Object -Average).Average
            $stats[$d] = [double]$avg
        }
        catch { $stats[$d] = 50.0 }
    }
    return $stats
}

function Invoke-Cleanup {
    foreach ($folder in $TargetFolders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }

        # 1) Cleanup stale temp outputs
        $cutoff = (Get-Date).AddHours(-24)
        Get-ChildItem -LiteralPath $folder -Recurse -Filter "hb_temp_*.mkv" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # 2) Safe .bak recovery
        $baks = Get-ChildItem -LiteralPath $folder -Recurse -Filter "*.bak" -ErrorAction SilentlyContinue
        foreach ($bak in $baks) {
            $originalPath = $bak.FullName.Substring(0, $bak.FullName.Length - 4)

            if (-not (Test-Path -LiteralPath $originalPath)) {
                try {
                    Move-Item -LiteralPath $bak.FullName -Destination $originalPath -Force
                    Write-BatchLog -InputPath $bak.FullName -OutputPath $originalPath -Strategy "Recovery" -Old_MB ([math]::Round($bak.Length/1MB,2)) -Status "Recovery-RestoredMissingOriginal"
                }
                catch {
                    Write-BatchLog -InputPath $bak.FullName -OutputPath $originalPath -Strategy "Recovery" -Old_MB ([math]::Round($bak.Length/1MB,2)) -Status "Recovery-RestoreFailed" -Detail $_.Exception.Message
                }
            }
            else {
                # Original exists; do not overwrite. Flag for manual check only if probe fails.
                $probe = Invoke-FfprobeJson $originalPath @("-show_format")
                if (-not $probe -or -not $probe.format) {
                    Write-BatchLog -InputPath $originalPath -OutputPath $bak.FullName -Strategy "Recovery" -Status "Warning-OriginalProbeFailed-BakExists" -Detail "ffprobe exit=$($Global:LastFfprobeExitCode)"
                }
            }
        }
    }
}

try {
    Invoke-Cleanup

    # 3) Build per-drive queues
    $queues = @{} # drive -> List[object]
    $cutoffDate = (Get-Date).AddDays(-30)

    foreach ($folder in $TargetFolders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }

        $files = Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue |
                 Where-Object { $Global:ValidExtensions -contains $_.Extension.ToLower() }

        foreach ($f in $files) {
            if ($f.LastWriteTime -ge $cutoffDate) {
                Write-BatchLog -InputPath $f.FullName -Strategy "Queue" -Old_MB ([math]::Round($f.Length/1MB,2)) -Status "Skipped-TooNew" -Detail "LastWrite=$($f.LastWriteTime.ToString('yyyy-MM-dd'))"
                continue
            }

            $drive = (Split-Path -Qualifier $f.FullName)
            if ([string]::IsNullOrWhiteSpace($drive)) { $drive = "UNC" }

            if (-not $queues.ContainsKey($drive)) {
                $queues[$drive] = New-Object 'System.Collections.Generic.List[object]'
            }

            $queues[$drive].Add([pscustomobject]@{ FullPath = $f.FullName; Size = $f.Length })
        }
    }

    # Sort each drive queue (largest first)
    foreach ($k in @($queues.Keys)) {
        $sorted = $queues[$k] | Sort-Object Size -Descending
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $sorted) { $list.Add($item) }
        $queues[$k] = $list
    }

    # 4) Traffic controller loop
    while ($true) {
        if (Test-Path -LiteralPath $LockFile) { break }

        $activeDrives = @($queues.Keys | Where-Object { $queues[$_].Count -gt 0 -and $_ -ne "UNC" })
        if (-not $activeDrives -or $activeDrives.Count -eq 0) { break }

        $driveStats = Get-DriveIdleStats -DrivesToCheck $activeDrives
        $sortedDrives = $driveStats.GetEnumerator() | Sort-Object Value -Descending

        $driveToProcess = $null
        foreach ($d in $sortedDrives) {
            if ($queues.ContainsKey($d.Key) -and $queues[$d.Key].Count -gt 0) { $driveToProcess = $d.Key; break }
        }
        if (-not $driveToProcess) { break }

        $next = $queues[$driveToProcess][0]
        $queues[$driveToProcess].RemoveAt(0)

        $procArgs = @(
            "-NoProfile",
            "-NonInteractive",
            "-NoLogo",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$Executor`"",
            "-ScanPath", "`"$($next.FullPath)`"",
            "-LogFile", "`"$LogPath`"",
            "-NoPause",
            "-NormalPriority"
        )

        Start-Process -FilePath "powershell.exe" -ArgumentList $procArgs -WindowStyle Hidden -Wait
    }
}
catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Media Fix Error", 0, 16)
}
