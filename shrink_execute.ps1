# --- shrink_execute.ps1 (V75 - Atomic Swap Safe) ---
# Worker:
# - Runs efficiently in background.
# - Logs all actions to shrink_log.csv.
# - No interactive pauses.
# - FIX: Uses [System.IO.File]::Replace for atomic, data-safe swaps.
# - FIX: Automatically handles cross-volume temp files.

param(
    [string]$ScanPath = ".",
    [string]$TempPath = "",
    [int]$MinSavingsMB = 50,
    [string]$LogFile = "shrink_log.csv", # Legacy param kept for compatibility
    [switch]$Force = $false,
    [switch]$NoPause = $false,
    [switch]$WhatIf = $false
)

Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

try {
    . (Join-Path $ScriptDir "media_common.ps1")
    Test-MediaTools


    # --- 1) RESOURCE MODE / PRIORITY ---
    try {
        $mode = "Light"
        $cfgMode = Get-Cfg "Shrink" "ResourceMode"
        if ($cfgMode) { $mode = $cfgMode }

        $p = Get-Process -Id $PID
        switch ($mode) {
            "Light"  { $p.PriorityClass = "Idle" }
            "Medium" { $p.PriorityClass = "BelowNormal" }
            "High"   { $p.PriorityClass = "Normal" }
        }
    } catch {}

    # --- 2) PATH VALIDATION ---
    $ScanPath = Resolve-ScanPath $ScanPath
    $file = Get-Item -LiteralPath $ScanPath

    # Root Protection
    $parent = Split-Path -Path $file.FullName -Parent
    $root = [System.IO.Path]::GetPathRoot($file.FullName)
    if ($parent.TrimEnd('\') -eq $root.TrimEnd('\')) {
        Write-MediaLog -InputPath $file.FullName -Status "Skipped-RootSafety"
        exit
    }

    # --- 3) PROBE ---
    $info = Invoke-FfprobeJson $file.FullName @("-show_format","-show_streams")
    if (-not $info) { throw "FFprobe failed to read file." }

    $v = Get-PrimaryVideoStream $info
    if (-not $v) { throw "No video stream detected." }

    $width = TryParse-Int (Get-JsonProp $v "width") 0
    $height = TryParse-Int (Get-JsonProp $v "height") 0
    $codec = [string](Get-JsonProp $v "codec_name")
    
    $duration = TryParse-Double (Get-JsonProp $info.format "duration") 0
    $sizeBytes = TryParse-Double (Get-JsonProp $info.format "size") 0
    if ($sizeBytes -le 0) { $sizeBytes = $file.Length }

    $br = TryParse-Double (Get-JsonProp $info.format "bit_rate") 0
    if ($br -eq 0 -and $duration -gt 0) { $br = ($sizeBytes * 8) / $duration }
    $kbps = [math]::Round($br / 1000)

    # --- 4) DECISION ENGINE ---
    if ($codec -match "hevc|h265") {
        $threshold = 4000
        if ($width -gt 2500) { $t = Get-Cfg "Media" "Threshold4K"; if($t){$threshold=$t} }
        elseif ($width -lt 1280) { $t = Get-Cfg "Media" "ThresholdSD"; if($t){$threshold=$t} }
        else { $t = Get-Cfg "Media" "Threshold1080"; if($t){$threshold=$t} }

        if ($kbps -lt $threshold -and -not $Force) {
            Write-MediaLog -InputPath $file.FullName -Status "Skipped-Efficient" -OrigVideo "$codec ${width}x${height}" -Old_MB ([math]::Round($file.Length/1MB,2))
            exit
        }
    }

    # Low Disk Space Check
    $free = Get-PathFreeSpace $file.DirectoryName
    $minFree = 50
    $cfgMin = Get-Cfg "Batch" "MinFreeSpaceGB"
    if ($cfgMin) { $minFree = [int]$cfgMin }
    
    if (($free / 1GB) -lt $minFree) {
        exit 10 # Signal Controller to pause
    }

    # --- 5) ENCODE SETUP ---
    $workDir = $file.DirectoryName
    $cfgTemp = Get-Cfg "Shrink" "TempPath"
    if (-not [string]::IsNullOrWhiteSpace($cfgTemp) -and (Test-Path -LiteralPath $cfgTemp)) {
        $workDir = $cfgTemp
    }
    
    $tempFile = Join-Path $workDir ("hb_temp_" + [Guid]::NewGuid().ToString("N") + ".mkv")
    
    # --- 6) HANDBRAKE ARGS ---
    $args = @("-i", $file.FullName, "-o", $tempFile, "-f", "av_mkv", "--all-subtitles", "--all-audio")
    
    if ($Global:MediaConfig['Media']['EncoderArgs10']) {
        $args += $Global:MediaConfig['Media']['EncoderArgs10']
    } else {
        $args += @("-e", "x265_10bit")
    }

    $preset = Get-Cfg "Media" "Preset"
    if (-not $preset) { $preset = "quality" }
    $args += @("--encoder-preset", $preset, "-q", "24")

    # --- 7) EXECUTE ---
    $startDT = Get-Date
    & $Global:HbPath @args
    $exitCode = $LASTEXITCODE
    $endDT = Get-Date

    # --- 8) VERIFY & SWAP (Atomic Safe) ---
    if ($exitCode -ne 0) {
        Write-MediaLog -InputPath $file.FullName -Status "Failed-HandBrake" -Detail "ExitCode=$exitCode"
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
    elseif (-not (Test-Path -LiteralPath $tempFile)) {
        Write-MediaLog -InputPath $file.FullName -Status "Failed-MissingOutput"
    }
    else {
        $newSize = (Get-Item -LiteralPath $tempFile).Length
        $oldSize = $file.Length
        
        $oldMB = [math]::Round($oldSize / 1MB, 2)
        $newMB = [math]::Round($newSize / 1MB, 2)
        $savedMB = [math]::Round($oldMB - $newMB, 2)

        if ($newSize -ge $oldSize) {
            Remove-Item -LiteralPath $tempFile -Force
            Write-MediaLog -InputPath $file.FullName -Old_MB $oldMB -New_MB $newMB -Status "Skipped-Bloat"
        }
        else {
            # --- ATOMIC SWAP LOGIC START ---
            $bakFile = $file.FullName + ".bak"
            
            try {
                # 1. Cross-Volume Check
                # System.IO.File.Replace requires both files to be on the same volume.
                $sourceRoot = [System.IO.Path]::GetPathRoot($file.FullName).ToLower()
                $tempRoot   = [System.IO.Path]::GetPathRoot($tempFile).ToLower()
                
                if ($sourceRoot -ne $tempRoot) {
                    # Move temp to source folder first
                    $tempInSrc = Join-Path $file.DirectoryName ("hb_temp_" + [Guid]::NewGuid().ToString("N") + ".mkv")
                    Move-Item -LiteralPath $tempFile -Destination $tempInSrc -Force -ErrorAction Stop
                    $tempFile = $tempInSrc
                }

                # 2. Atomic Replacement
                # This performs a Replace + Backup in one kernel operation (on NTFS)
                [System.IO.File]::Replace($tempFile, $file.FullName, $bakFile)
                
                # 3. Success Cleanup
                Remove-Item -LiteralPath $bakFile -Force -ErrorAction SilentlyContinue
                
                $dur = ($endDT - $startDT).ToString("hh\:mm\:ss")
                $encName = if ($Global:EncoderName) { $Global:EncoderName } else { "Unknown" }

                Write-MediaLog -InputPath $file.FullName -OutputPath $file.FullName -Old_MB $oldMB -New_MB $newMB -Saved_MB $savedMB -Status "Success" -Detail "$encName, $dur" -OrigVideo "$codec ${width}x${height}"
            }
            catch {
                # 4. Rollback / Failure Handling
                Write-MediaLog -InputPath $file.FullName -Status "Failed-Swap" -Detail $_.Exception.Message
                
                # Attempt to restore backup if it exists (Manual Rollback)
                try {
                    if (Test-Path -LiteralPath $bakFile) {
                        Move-Item -LiteralPath $bakFile -Destination $file.FullName -Force
                    }
                } catch {
                     Write-MediaLog -InputPath $file.FullName -Status "CRITICAL-RollbackFailed" -Detail "Manual intervention required. Check .bak file."
                }
                
                # Cleanup stranded temp file
                if (Test-Path -LiteralPath $tempFile) { 
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue 
                }
            }
            # --- ATOMIC SWAP LOGIC END ---
        }
    }

} catch {
    # Critical Failure Logging
    try { 
        Write-MediaLog -InputPath $ScanPath -Status "CRITICAL" -Detail $_.Exception.Message 
    } catch {}
    exit 1
}