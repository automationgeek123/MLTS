# --- run_batch_job.ps1 (V76 - Safe Arguments) ---
# Controller:
# - FIX: Uses safe ArgumentList array for worker startup (Fixes quoting issues).
# - Setup Wizard: Full interactive setup (Tools, Temp, Priority, Filters).
# - Production Mode: Runs workers HIDDEN (no popup windows).
# - Safe Config Access: Uses Get-Cfg to prevent Strict Mode crashes.

Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

# --- 1) BOOTSTRAP & FIRST RUN ---
$CommonFile   = Join-Path $ScriptDir "media_common.ps1"
$SettingsFile = Join-Path $ScriptDir "media_user_settings.json"

if (-not (Test-Path -LiteralPath $SettingsFile)) {
    Write-Host "--- FIRST RUN SETUP ---" -ForegroundColor Cyan
    Write-Host "media_user_settings.json not found. Let's create it." -ForegroundColor Gray
    
    # 1. Folders
    $folders = @()
    Write-Host "`n1. Folders to scan (One per line, Empty line to finish):" -ForegroundColor White
    while ($true) {
        $f = Read-Host "   Path"
        if ([string]::IsNullOrWhiteSpace($f)) { break }
        $folders += $f
    }

    # 2. Tools
    Write-Host "`n2. Tool Paths (Press Enter for default if in PATH/Folder):" -ForegroundColor White
    $hb = Read-Host "   HandBrakeCLI.exe path [Default: HandBrakeCLI.exe]"
    if ([string]::IsNullOrWhiteSpace($hb)) { $hb = "HandBrakeCLI.exe" }

    $ff = Read-Host "   ffprobe.exe path      [Default: ffprobe.exe]"
    if ([string]::IsNullOrWhiteSpace($ff)) { $ff = "ffprobe.exe" }

    # 3. Temp Path
    Write-Host "`n3. Transcoding (Press Enter to use source folder):" -ForegroundColor White
    $tmp = Read-Host "   Temp Folder path"

    # 4. Priority
    Write-Host "`n4. Resource Mode (Controls Process Priority):" -ForegroundColor White
    $mode = Read-Host "   [Light, Medium, Heavy] (Default: Medium)"
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "Medium" }

    # 5. Filters
    Write-Host "`n5. Filters:" -ForegroundColor White
    $recentMins = Read-Host "   Skip files modified in last N minutes (Download protection) [Default: 15]"
    if ([string]::IsNullOrWhiteSpace($recentMins)) { $recentMins = 15 }

    $olderDays = Read-Host "   Only process files older than N days (Legacy filter)        [Default: 15]"
    if ([string]::IsNullOrWhiteSpace($olderDays)) { $olderDays = 15 }

    $defaultSettings = [ordered]@{
        Tools = @{ 
            HandBrakeCli = $hb; 
            Ffprobe = $ff 
        }
        Shrink = @{ 
            TempPath = $tmp; 
            ResourceMode = $mode; 
            DolbyVisionPolicy = "RequirePreserve"; 
            RecentlyModifiedSkipMinutes = [int]$recentMins
        }
        Batch = @{ 
            TargetFolders = $folders; 
            MinFreeSpaceGB = 50; 
            SkipFilesNewerThanDays = [int]$olderDays; 
            SortOrder = "SmallestFirst";
            RunWindowStart = "23:00"; 
            RunWindowEnd = "07:00";
            ExcludeNameRegex = "^hb_temp_|sample|trailer|extras"
        }
    }
    $defaultSettings | ConvertTo-Json -Depth 3 | Set-Content -Path $SettingsFile -Encoding UTF8
    Write-Host "`nSettings saved! Starting main script..." -ForegroundColor Green
    Start-Sleep -Seconds 1
}

. $CommonFile
Test-MediaTools

$Executor = Join-Path $ScriptDir "shrink_execute.ps1"
if (-not (Test-Path -LiteralPath $Executor)) { throw "Worker script missing: $Executor" }
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
    if (-not (Test-Path -LiteralPath $folder)) { continue }
    $files = Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue | ? { $Global:ValidExtensions -contains $_.Extension.ToLower() }
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
    if (Test-Path -LiteralPath $LockFile) { Write-Host "Paused."; break }
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

    # --- SAFE EXECUTION (Argument List) ---
    $psArgs = @(
        "-NoProfile", 
        "-ExecutionPolicy", "Bypass", 
        "-File", $Executor,
        "-ScanPath", $file.FullName,
        "-NoPause"
    )
    
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WindowStyle Hidden -Wait -PassThru
    
    if ($p.ExitCode -eq 10) {
        $ans = Show-Popup -Text "Low Disk Space on $drive. Skip drive?" -Title "Space Warning" -Buttons "YesNo"
        if ($ans -eq 6) { $SkippedDrives += $drive } else { exit }
    }
    Invoke-Cleanup
}
Write-Host "Done." -ForegroundColor Green