<#!
.SYNOPSIS
    Video Shrink Automation (V48)
.DESCRIPTION
    - Fix: correctly identifies real video stream (ignores cover art / attached pictures)
    - Safe swap with .bak restore
    - Validates: duration, audio/sub counts, savings threshold, HEVC output codec
    - Free-space checks use work/temp volume and destination volume
    - Consistent CSV schema for all rows
    - Supports -WhatIf (dry-run logging)
#>

param(
    [string]$ScanPath = ".",
    [string]$TempPath = "",
    [int]$MinSavingsMB = 50,
    [string]$LogFile = "shrink_log.csv",
    [switch]$Force = $false,
    [switch]$NoPause = $false,
    [switch]$WhatIf = $false,
    [switch]$NormalPriority = $false
)

if (-not $NormalPriority) {
    try { (Get-Process -Id $PID).PriorityClass = 'Idle' } catch { }
}

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = "." }

. (Join-Path $ScriptDir "media_common.ps1")
Test-MediaTools

$ScanPath = Resolve-ScanPath $ScanPath

$LogPath = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }
$LogCols = $Global:ShrinkLogColumns

function Write-ShrinkLog {
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

# --- File list (supports file OR folder) ---
$item = Get-Item -LiteralPath $ScanPath -ErrorAction SilentlyContinue
if ($item -is [System.IO.FileInfo]) {
    $files = @($item)
} else {
    $files = Get-ChildItem -LiteralPath $ScanPath -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $Global:ValidExtensions -contains $_.Extension.ToLower() } |
             Sort-Object Length -Descending
}

if (-not $files -or $files.Count -eq 0) {
    Write-Host "No matching files found." -ForegroundColor Yellow
    if (-not $NoPause) { Pause }
    exit
}

$i = 0
foreach ($file in $files) {
    $i++
    $ext = $file.Extension.ToLower()
    if ($Global:ValidExtensions -notcontains $ext) { continue }

    Write-Progress -Activity "Shrinking Library" -Status "Checking $($file.Name)" -PercentComplete (($i / $files.Count) * 100)

    $oldBytes = $file.Length
    $oldMB = [math]::Round($oldBytes / 1MB, 2)

    # --- Probe ---
    $info = Invoke-FfprobeJson $file.FullName @("-show_format","-show_streams")
    if (-not $info) {
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "Skipped-ProbeError" -Detail "ffprobe exit=$($Global:LastFfprobeExitCode)"
        continue
    }

    # IMPORTANT: ignore attached cover art streams
    $v = Get-PrimaryVideoStream $info
    if (-not $v) {
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "Skipped-NoVideo" -Detail "No primary video stream"
        continue
    }

    $origAudCount = ($info.streams | Where-Object { $_.codec_type -eq "audio" }).Count
    $origSubCount = ($info.streams | Where-Object { $_.codec_type -eq "subtitle" }).Count


    # --- Source summaries (for logging / decisions) ---
    $origVideo = Get-VideoSummary -ProbeJson $info -VideoStream $v
    $origAudio = Get-AudioSummary -ProbeJson $info
    $origDV = [int](Test-IsDolbyVision -ProbeJson $info -VideoStream $v)
    $srcIs10OrHdr = Test-Is10BitOrHDR $v
    $srcIsDvOrHdr = ($srcIs10OrHdr -or ($origDV -eq 1))
    $encode10 = [bool]$srcIsDvOrHdr  # default; may be overridden by Prefer10Bit later
    $audioPlan = ""
    $width = TryParse-Int $v.width 1920
    $duration = TryParse-Double $info.format.duration 0

    if ($duration -le 0) {
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "Skipped-NoDuration" -Detail "ffprobe duration missing/invalid"
        continue
    }

    $bitrate = TryParse-Double $info.format.bit_rate 0
    if ($bitrate -le 0) { $bitrate = [math]::Round(($oldBytes * 8) / ($duration * 1000)) } # kbps*1000
    $kbps = [math]::Round($bitrate / 1000)

    $codec = [string]$v.codec_name

    # --- Decide ---
    $process = $false
    $reason = ""

    if ($Force) {
        $process = $true
        $reason = "Force"
    }
    elseif ($codec -match '^(h264|avc|mpeg2video|mpeg4|vc1|msmpeg4)$') {
        $process = $true
        $reason = "Upgrade ($codec)"
    }
    else {
        if ($width -gt 3000 -and $kbps -gt $Global:MediaConfig.Threshold4K) { $process = $true; $reason = "4K Bloat" }
        elseif ($width -le 3000 -and $kbps -gt $Global:MediaConfig.Threshold1080) { $process = $true; $reason = "1080p Bloat" }
    }

    if (-not $process) {
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "Skipped-Efficient" -Detail ("codec={0} kbps={1}" -f $codec,$kbps) -OrigVideo $origVideo -OrigAudio $origAudio -OrigDV $origDV -Encode10 ([int]$encode10) -AudioPlan "skip"
        continue
    }

    # --- Determine 10-bit encoding mode ---
    $pref = [string]$Global:MediaConfig.Prefer10Bit
    if ($pref -eq "always") { $encode10 = $true }
    elseif ($pref -eq "never") { $encode10 = $false }
    else { $encode10 = $srcIsDvOrHdr }

    if ($WhatIf) {
        Write-Host "[WHATIF] Would process: $($file.Name) [$reason] encode10=$encode10 DV=$origDV audioPlan=$audioPlan" -ForegroundColor Yellow
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "WhatIf" -Strategy $reason -Detail "encode10=$encode10"
        continue
    }

    # --- Space checks ---
    $workDir = if (-not [string]::IsNullOrWhiteSpace($TempPath)) { $TempPath } else { $file.DirectoryName }
    if (-not (Test-Path -LiteralPath $workDir)) {
        try { New-Item -ItemType Directory -Path $workDir -Force | Out-Null } catch { }
    }

    $workSpace = Get-PathFreeSpace $workDir
    if ($workSpace -lt ($oldBytes * 1.5)) {
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "Skipped-LowSpace" -Strategy $reason -Detail "workDir=$workDir"
        continue
    }

    Write-Host "Processing: $($file.Name) [$reason] encode10=$encode10" -ForegroundColor Cyan
    Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "Started" -Strategy $reason -Detail "workDir=$workDir encode10=$encode10"

    # --- Encode ---
    $tempFile = Join-Path $workDir ("hb_temp_" + [Guid]::NewGuid().ToString("N") + ".mkv")

        # --- Audio plan (optical-friendly): make AC3 the first output track ---
    $audioPlan = ""
    $hbAudioArgs = @()
    $audCount = @($info.streams | Where-Object { $_.codec_type -eq "audio" }).Count
    if ($audCount -le 0) {
        $hbAudioArgs = @("--audio","none")
        $audioPlan = "none"
    }
    else {
        $audioNums = 1..$audCount

        $bestAc3 = Get-BestAc3AudioTrackNum -ProbeJson $info
        if ($bestAc3 -gt 0) {
            # AC3 already exists -> put best AC3 first, then copy everything else.
            $ordered = @($bestAc3) + @($audioNums | Where-Object { $_ -ne $bestAc3 })
            $encs = @("copy") * $ordered.Count
            $abs  = @("0") * $ordered.Count
            $hbAudioArgs = @(
                "--audio", ($ordered -join ","),
                "--aencoder", ($encs -join ","),
                "--ab", ($abs -join ","),
                "--audio-copy-mask", "aac,ac3,dts,dtshd,mp3",
                "--audio-fallback", "ffac3"
            )
            $audioPlan = "ac3-first(copy) srcTrack=$bestAc3"
        }
        else {
            # No AC3 present -> add an AC3 track derived from the primary track, then copy the rest.
            $primary = Get-PrimaryAudioTrackNum -ProbeJson $info
            $rest = @($audioNums | Where-Object { $_ -ne $primary })
            $ordered = @($primary, $primary) + $rest
            $encs = @("ffac3","copy") + (@("copy") * $rest.Count)
            $abs  = @([string]$Global:MediaConfig.Ac3BitrateK,"0") + (@("0") * $rest.Count)
            $hbAudioArgs = @(
                "--audio", ($ordered -join ","),
                "--aencoder", ($encs -join ","),
                "--ab", ($abs -join ","),
                "--audio-copy-mask", "aac,ac3,dts,dtshd,mp3",
                "--audio-fallback", "ffac3"
            )
            $audioPlan = "add-ac3(track=$primary)"
        }
    }

    $hbArgs = @(
        "-i", $file.FullName,
        "-o", $tempFile,
        "-f", "av_mkv",
        "--all-subtitles",
        "-q", "24",
        "--encoder-preset", $Global:MediaConfig.Preset
    ) + $hbAudioArgs

    if ($encode10) { $hbArgs += $Global:MediaConfig.EncoderArgs10 } else { $hbArgs += $Global:MediaConfig.EncoderArgs8 }

    & $Global:HbPath @hbArgs
    $hbExit = $LASTEXITCODE

    if ($hbExit -ne 0 -or -not (Test-Path -LiteralPath $tempFile)) {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -Status "Crashed" -Strategy $reason -Detail ("HandBrake exit={0}" -f $hbExit) -OrigVideo $origVideo -OrigAudio $origAudio -OrigDV $origDV -Encode10 ([int]$encode10) -AudioPlan $audioPlan
        continue
    }

    $newBytes = (Get-Item -LiteralPath $tempFile).Length
    $newMB = [math]::Round($newBytes / 1MB, 2)
    $savedMB = [math]::Round(($oldBytes - $newBytes) / 1MB, 2)

    # --- Validate output ---
    $newVideo = ""
    $newAudio = ""
    $newDV = 0
    $validDV = $true

    $valid = $false
    $failDetail = ""
    for ($k = 1; $k -le 3; $k++) {
        Start-Sleep -Seconds (2 * $k)
        $newInfo = Invoke-FfprobeJson $tempFile @("-show_format","-show_streams")
        if (-not $newInfo) {
            $failDetail = "ffprobe output fail (exit=$($Global:LastFfprobeExitCode))"
            continue
        }

        $newV = Get-PrimaryVideoStream $newInfo

        if ($newV) {
            $newVideo = Get-VideoSummary -ProbeJson $newInfo -VideoStream $newV
            $newDV = [int](Test-IsDolbyVision -ProbeJson $newInfo -VideoStream $newV)
        }
        $newAudio = Get-AudioSummary -ProbeJson $newInfo
        $validDV = ($origDV -ne 1) -or ($newDV -eq 1)
        $newAud = ($newInfo.streams | Where-Object { $_.codec_type -eq "audio" }).Count
        $newSub = ($newInfo.streams | Where-Object { $_.codec_type -eq "subtitle" }).Count

        $newDur = TryParse-Double $newInfo.format.duration 0
        $validDur = ($newDur -ge ($duration * 0.95))
        $validStreams = ($newAud -ge $origAudCount) -and ($newSub -ge $origSubCount)
        $validSave = (($oldBytes - $newBytes) -ge ($MinSavingsMB * 1MB))
        $validCodec = ($newV -and ([string]$newV.codec_name -match '^(hevc|h265)$'))

        if ($validDur -and $validStreams -and $validSave -and $validCodec -and $validDV) { $valid = $true; break }
        $failDetail = "Dur:$validDur Strm:$validStreams Save:$validSave Codec:$validCodec DV:$validDV"
    }

    if (-not $valid) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -New_MB $newMB -Saved_MB $savedMB -Status "Fail-Validation" -Strategy $reason -Detail $failDetail
        continue
    }

    # --- Destination free space (for swap) ---
    $destSpace = Get-PathFreeSpace $file.DirectoryName
    if ($destSpace -lt $newBytes) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -New_MB $newMB -Saved_MB $savedMB -Status "DiskFull" -Strategy $reason -Detail "destFree=$([math]::Round($destSpace/1GB,2))GB"
        continue
    }

    # --- Swap ---
    $finalPath = "-"
    $bakFile = $null
    $final = $null

    try {
        $origCreation = $file.CreationTime
        $origLastWrite = $file.LastWriteTime

        $final = [System.IO.Path]::ChangeExtension($file.FullName, ".mkv")
        if ($final -ne $file.FullName -and (Test-Path -LiteralPath $final)) {
            $final = Join-Path $file.DirectoryName ($file.BaseName + "_HEVC_" + (Get-Random -Minimum 1000 -Maximum 9999) + ".mkv")
        }

        $bakFile = $file.FullName + ".bak"

        Move-Item -LiteralPath $file.FullName -Destination $bakFile -Force
        Move-Item -LiteralPath $tempFile -Destination $final -Force

        $newItem = Get-Item -LiteralPath $final
        $newItem.CreationTime = $origCreation
        $newItem.LastWriteTime = $origLastWrite

        Remove-Item -LiteralPath $bakFile -Force

        $finalPath = $final
        Write-Host "   [SUCCESS] Saved $savedMB MB" -ForegroundColor Green
        Write-ShrinkLog -InputPath $file.FullName -OutputPath $finalPath -Old_MB $oldMB -New_MB $newMB -Saved_MB $savedMB -Status "Success" -Strategy $reason -Detail "encode10=$encode10"
    }
    catch {
        # Remove possibly corrupt output first, then restore original
        if ($final -and (Test-Path -LiteralPath $final)) {
            Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
        }
        if ($bakFile -and (Test-Path -LiteralPath $bakFile)) {
            Move-Item -LiteralPath $bakFile -Destination $file.FullName -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        Write-ShrinkLog -InputPath $file.FullName -Old_MB $oldMB -New_MB $newMB -Saved_MB $savedMB -Status "SwapError" -Strategy $reason -Detail $_.Exception.Message
    }
}

if (-not $NoPause) { Pause }
