# --- run_batch_job.ps1 (V69 - Final Production) ---
# Controller:
# - Production Mode: Runs workers HIDDEN (no popup windows).
# - Safe Config Access: Uses Get-Cfg to prevents Strict Mode crashes.
# - Logs "Picked" status before execution.

Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

# --- 1) BOOTSTRAP & FIRST RUN ---
$CommonFile   = Join-Path $ScriptDir "media_common.ps1"
$SettingsFile = Join-Path $ScriptDir "media_user_settings.json"

if (-not (Test-Path -LiteralPath $SettingsFile)) {
    # (Simplified setup logic maintained for safety)
    $folders = @(); while ($true) { $f = Read-Host "Path to scan"; if (-not $f) { break }; $folders += $f }
    $def = [ordered]@{ 
        Tools=@{HandBrakeCli="HandBrakeCLI.exe";Ffprobe="ffprobe.exe"}; 
        Shrink=@{ResourceMode="Light";TempPath="";DolbyVisionPolicy="RequirePreserve"}; 
        Batch=@{TargetFolders=$folders;MinFreeSpaceGB=50;SkipFilesNewerThanDays=15;SortOrder="SmallestFirst";RunWindowStart="23:00";RunWindowEnd="07:00"} 
    }
    $def | ConvertTo-Json -Depth 3 | Set-Content $SettingsFile
}

. $CommonFile
Test-MediaTools

$Executor = Join-Path $ScriptDir "shrink_execute.ps1"
if (-not (Test-Path $Executor)) { throw "Worker script missing: $Executor" }
$LockFile = Join-Path $ScriptDir "PAUSE.lock"
$Global:BatchOverrideWindow = $false

# --- 2) HELPERS ---
function Get-Cfg { 
    param($Key1, $Key2) 
    if ($Global:MediaConfig.Contains($Key1)) {
        $k1 = $Global:MediaConfig[$Key1]
        if ($k1 -is [System.Collections.IDictionary] -and $k1.Contains($Key2)) { return $k1[$Key2] }
    }
    return $null
}

function Wait-For-RunWindow {
    if ($Global:BatchOverrideWindow) { return }
    $startStr = Get-Cfg "Batch" "RunWindowStart"; $endStr = Get-Cfg "Batch" "RunWindowEnd"
    if (-not $startStr -or -not $endStr -or ($startStr -eq "00:00" -and $endStr -eq "24:00")) { return }

    do {
        $now = Get-Date
        try {
            $s = $startStr.Split(':'); $e = $endStr.Split(':')
            $tS = Get-Date -Hour $s[0] -Minute $s[1] -Second 0; $tE = Get-Date -Hour $e[0] -Minute $e[1] -Second 0
        } catch { return }

        $inWindow = if ($tS -le $tE) { ($now -ge $tS -and $now -le $tE) } else { ($now -ge $tS -or $now -le $tE) }

        if (-not $inWindow) {
            $ans = Show-Popup -Text "Current time ($($now.ToString('HH:mm'))) is outside run window.`n`nRun anyway?" -Title "Night Mode" -Buttons "YesNo" -TimeoutSeconds 30
            if ($ans -eq 6) { $Global:BatchOverrideWindow = $true; return }
            
            $wake = $tS; if ($now -gt $tS) { $wake = $tS.AddDays(1) }
            Write-Host "Sleeping until $($wake.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Yellow
            Start-Sleep -Seconds ($wake - $now).TotalSeconds
        }
    } while (-not $inWindow)
}

function Get-DriveIdleStats {
    param($Drives)
    $stats = @{}; foreach ($d in $Drives) { try { $stats[$d] = ([double](Get-Counter "\LogicalDisk($d)\% Idle Time" -Max 1).CounterSamples.CookedValue) } catch { $stats[$d] = 50 } }; return $stats
}

# --- 3) BUILD QUEUE ---
Invoke-Cleanup
$TargetFolders = @(Get-Cfg "Batch" "TargetFolders")
if ($TargetFolders.Count -eq 0) { Write-Warning "No targets."; exit }

$Queues = @{}
$SkippedDrives = @()
$TotalFiles = 0
$excl = Get-Cfg "Batch" "ExcludeNameRegex"; $skipDays = [int](Get-Cfg "Batch" "SkipFilesNewerThanDays"); $cut = (Get-Date).AddDays(-$skipDays)

Write-Host "Scanning..." -ForegroundColor Cyan
foreach ($folder in $TargetFolders) {
    if (-not (Test-Path $folder)) { continue }
    $files = Get-ChildItem $folder -Recurse -File -ErrorAction SilentlyContinue | ? { $Global:ValidExtensions -contains $_.Extension.ToLower() }
    foreach ($f in $files) {
        if ($excl -and ($f.Name -match $excl)) { continue }
        if ($skipDays -gt 0 -and $f.LastWriteTime -gt $cut) { continue }
        $d = (Split-Path -Qualifier $f.FullName); if(-not $d){$d="UNC"}
        if(-not $Queues[$d]){$Queues[$d] = New-Object System.Collections.Generic.List[object]}
        $Queues[$d].Add($f)
        $TotalFiles++
    }
}

# Sort
$sortMode = Get-Cfg "Batch" "SortOrder"
if (-not $sortMode) { $sortMode = "SmallestFirst" }
Write-Host "Sorting ($sortMode)..." -ForegroundColor Magenta
foreach ($k in @($Queues.Keys)) {
    $l = $Queues[$k]; $sl = @()
    switch ($sortMode) {
        "SmallestFirst" { $sl = @($l | Sort Length) }
        "LargestFirst"  { $sl = @($l | Sort Length -Desc) }
        "Alphabetical"  { $sl = @($l | Sort Name) }
        Default         { $sl = @($l) }
    }
    $nl = New-Object System.Collections.Generic.List[object]; foreach($i in $sl){$nl.Add($i)}; $Queues[$k] = $nl
}

# --- 4) EXECUTE ---
Write-Host "Starting Batch ($TotalFiles files)..." -ForegroundColor Green

while ($true) {
    if (Test-Path $LockFile) { Write-Host "Paused."; break }
    Wait-For-RunWindow

    $active = @($Queues.Keys | ? { $Queues[$_].Count -gt 0 -and $SkippedDrives -notcontains $_ })
    if ($active.Count -eq 0) { break }

    $stats = Get-DriveIdleStats $active
    $drive = ($stats.GetEnumerator() | Sort Value -Desc | Select -First 1).Key
    
    $file = $Queues[$drive][0]; $Queues[$drive].RemoveAt(0)

    # Late-bound check
    $skipMins = [int](Get-Cfg "Shrink" "RecentlyModifiedSkipMinutes")
    if ($skipMins -gt 0) {
        if (((Get-Date)-$file.LastWriteTime).TotalMinutes -lt $skipMins) {
            Write-Host "Skipping (Active): $($file.Name)" -ForegroundColor DarkGray; continue
        }
    }

    # Log Pick
    Write-Host "Processing [$drive]: $($file.Name)" -ForegroundColor Green
    Write-MediaLog -InputPath $file.FullName -Status "Picked" -Strategy "Batch" -Detail "Drive=$drive"

    # Execute Hidden
    $escExe = $Executor.Replace("'","''"); $escPath = $file.FullName.Replace("'","''")
    $cmd = "& '$escExe' -ScanPath '$escPath' -NoPause"
    
    $p = Start-Process "powershell" -Arg "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd -WindowStyle Hidden -Wait -PassThru
    
    if ($p.ExitCode -eq 10) {
        $ans = Show-Popup -Text "Low Disk Space on $drive. Skip drive?" -Title "Space Warning" -Buttons "YesNo"
        if ($ans -eq 6) { $SkippedDrives += $drive } else { exit }
    }
    Invoke-Cleanup
}
Write-Host "Done." -ForegroundColor Green