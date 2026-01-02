# --- media_common.ps1 (V37) ---
# Shared configuration + robust helpers for the media scripts.
# Keep HandBrakeCLI.exe + ffprobe.exe in the same folder as these scripts.

Set-StrictMode -Version Latest

$Global:ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Global:ToolsDir)) { $Global:ToolsDir = "." }

$Global:HbPath = Join-Path $Global:ToolsDir "HandBrakeCLI.exe"
$Global:FfPath = Join-Path $Global:ToolsDir "ffprobe.exe"

# Use ONE extension list everywhere.
$Global:ValidExtensions = @(".mkv", ".mp4", ".avi", ".m4v", ".ts")

# Canonical shrink log schema (used by shrink + batch controller).
$Global:ShrinkLogColumns = @(
    "Date","InputPath","OutputPath","Strategy","Old_MB","New_MB","Saved_MB","Status","Detail",
    "OrigVideo","NewVideo","OrigAudio","NewAudio","OrigDV","NewDV","Encode10","AudioPlan"
)

# --- 1) HARDWARE DETECTION (choose encoder families) ---
$EncoderName = "CPU (Fallback)"
$EncoderArgs8  = @("-e","x265","--encoder-profile","main")
$EncoderArgs10 = @("-e","x265_10bit","--encoder-profile","main10")

try {
    $gpuNames = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join " | "
    if ($gpuNames -match "Intel" -or $gpuNames -match "UHD Graphics" -or $gpuNames -match "Iris") {
        $EncoderName = "Intel QSV"
        $EncoderArgs8  = @("-e","qsv_h265","--encoder-profile","main")
        $EncoderArgs10 = @("-e","qsv_h265_10bit","--encoder-profile","main10")
    }
    elseif ($gpuNames -match "NVIDIA" -or $gpuNames -match "GeForce" -or $gpuNames -match "Quadro") {
        $EncoderName = "NVIDIA NVENC"
        $EncoderArgs8  = @("-e","nvenc_h265","--encoder-profile","main")
        $EncoderArgs10 = @("-e","nvenc_h265_10bit","--encoder-profile","main10")
    }
    else {
        $EncoderName = "CPU (x265)"
        $EncoderArgs8  = @("-e","x265","--encoder-profile","main")
        $EncoderArgs10 = @("-e","x265_10bit","--encoder-profile","main10")
    }
}
catch { }

# --- 2) SHARED CONFIGURATION ---
# Prefer10Bit: "auto" (10-bit only for HDR/10-bit sources), "always", "never"
$Global:MediaConfig = [ordered]@{
    EncoderName   = $EncoderName
    Preset        = "quality"

    Threshold4K   = 8000
    Threshold1080 = 4000

    Target4K      = 5000
    Target1080    = 2500

    Speed4K       = 35
    Speed1080     = 200

    Prefer10Bit   = "auto"

    # Optical-friendly audio target
    Ac3Bitrate51K = 640
    Ac3Bitrate20K = 256
    RecentMinutes = 15
    # Legacy (kept for backward compatibility)
    Ac3BitrateK   = 640
SafeLangs     = @("eng","en","hin","hi","und")

    EncoderArgs8  = $EncoderArgs8
    EncoderArgs10 = $EncoderArgs10
}

# --- 3) ROBUST HELPERS ---
function Test-MediaTools {
    if (-not (Test-Path -LiteralPath $Global:HbPath)) { throw "HandBrakeCLI.exe not found at: $Global:HbPath" }
    if (-not (Test-Path -LiteralPath $Global:FfPath)) { throw "ffprobe.exe not found at: $Global:FfPath" }
}

# ffprobe wrapper. Returns JSON object or $null.
# Sets $Global:LastFfprobeExitCode to the most recent exit code.
function Invoke-FfprobeJson {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string[]] $ArgsList
    )
    $Global:LastFfprobeExitCode = $null
    try {
        $allArgs = @("-v","error","-print_format","json") + $ArgsList + @("--", $Path)
        $json = & $Global:FfPath @allArgs 2>$null
        $Global:LastFfprobeExitCode = $LASTEXITCODE
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function TryParse-Double {
    param($Value, [double] $Default = 0.0)
    $d = 0.0
    $style = [System.Globalization.NumberStyles]::Any
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -ne $Value -and [double]::TryParse([string]$Value, $style, $culture, [ref]$d)) { return $d }
    return $Default
}

function TryParse-Int {
    param($Value, [int] $Default = 0)
    $i = 0
    if ($null -ne $Value -and [int]::TryParse([string]$Value, [ref]$i)) { return $i }
    return $Default
}

function Get-FpsFromRateString {
    param([string]$Rate)
    if ([string]::IsNullOrWhiteSpace($Rate)) { return 0.0 }
    if ($Rate -match '^\s*(\d+)\s*/\s*(\d+)\s*$') {
        $num = TryParse-Double $Matches[1] 0
        $den = TryParse-Double $Matches[2] 0
        if ($den -gt 0) { return ($num / $den) }
    }
    return (TryParse-Double $Rate 0)
}

function Get-RealFps {
    param($StreamObj)
    $fps = 0.0
    if ($StreamObj -and $StreamObj.avg_frame_rate) { $fps = Get-FpsFromRateString ([string]$StreamObj.avg_frame_rate) }
    if ($fps -le 0 -and $StreamObj -and $StreamObj.r_frame_rate) { $fps = Get-FpsFromRateString ([string]$StreamObj.r_frame_rate) }
    if ($fps -le 0) { $fps = 24.0 }
    return $fps
}

function Normalize-LanguageTag {
    param([string]$Lang)
    if ([string]::IsNullOrWhiteSpace($Lang)) { return "und" }
    $clean = $Lang.Trim().ToLower()
    $parts = $clean.Split('-', '_')
    if ($parts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($parts[0])) { return $parts[0] }
    return $clean
}

function Get-PathFreeSpace {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if ([string]::IsNullOrWhiteSpace($root)) { return 0 }

        # UNC path: try to query free space via `dir` (no commas) and parse "bytes free".
        if ($root.StartsWith("\\\\")) {
            try {
                $share = $root.TrimEnd("\")
                $out = cmd /c "dir /-C ""$share""" 2>$null
                if ($out) {
                    $line = $out | Select-Object -Last 1
                    if ($line -match '(\d+)\s+bytes\s+free') {
                        return [int64]$Matches[1]
                    }
                    # Sometimes it's not the last line; scan all lines
                    foreach ($ln in $out) {
                        if ($ln -match '(\d+)\s+bytes\s+free') { return [int64]$Matches[1] }
                    }
                }
            } catch {}
            # Fallback: unknown free space, assume large to avoid false negatives.
            return 999GB
        }

        $drive = Get-PSDrive | Where-Object { $root -like "$($_.Name):*" } | Select-Object -First 1
        if ($drive) { return $drive.Free }
        return 0
    } catch { return 0 }
}

function Resolve-ScanPath {
    param([string]$InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath)) { $InputPath = "." }
    if (-not (Test-Path -LiteralPath $InputPath)) { throw "Path not found: $InputPath" }
    return (Resolve-Path -LiteralPath $InputPath).Path
}

# Picks the real video stream:
# - Excludes cover art / attached pictures (disposition.attached_pic=1)
# - Prefers the highest-resolution remaining stream
function Get-PrimaryVideoStream {
    param($ProbeJson)

    if (-not $ProbeJson -or -not $ProbeJson.streams) { return $null }

    $candidates = $ProbeJson.streams | Where-Object {
        $_.codec_type -eq "video" -and -not ($_.disposition -and $_.disposition.attached_pic -eq 1)
    }

    if (-not $candidates -or $candidates.Count -eq 0) {
        return ($ProbeJson.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1)
    }

    return ($candidates | Sort-Object @{
        Expression = { (TryParse-Int $_.width 0) * (TryParse-Int $_.height 0) };
        Descending = $true
    } | Select-Object -First 1)
}

function Test-Is10BitOrHDR {
    param($VideoStream)

    if (-not $VideoStream) { return $false }

    $pixFmt = [string]$VideoStream.pix_fmt
    $profile = [string]$VideoStream.profile
    $bprs = TryParse-Int $VideoStream.bits_per_raw_sample 0

    $colorTransfer = [string]$VideoStream.color_transfer
    $colorPrimaries = [string]$VideoStream.color_primaries
    $colorSpace = [string]$VideoStream.color_space

    $is10Bit = ($bprs -eq 10) -or ($pixFmt -match "10le") -or ($profile -match "Main 10|High 10")
    $isHDR = ($colorTransfer -match "smpte2084|arib-std-b67") -or ($colorPrimaries -match "bt2020") -or ($colorSpace -match "bt2020")
    return ($is10Bit -or $isHDR)
}

# Dolby Vision detection:
# - Looks for 'dvh1'/'dvhe' codec tags OR side_data_type that contains DOVI/Dolby Vision.
function Test-IsDolbyVision {
    param(
        [Parameter(Mandatory)] $ProbeJson,
        [Parameter(Mandatory)] $VideoStream
    )

    if (-not $ProbeJson -or -not $VideoStream) { return $false }

    $tag = [string]$VideoStream.codec_tag_string
    if ($tag -match "^(dvh1|dvhe)$") { return $true }

    $codecTag = [string]$VideoStream.codec_tag
    if ($codecTag -match "dvh1|dvhe") { return $true }

    if ($VideoStream.side_data_list) {
        foreach ($sd in $VideoStream.side_data_list) {
            $t = [string]$sd.side_data_type
            if ($t -match "DOVI|Dolby\s*Vision") { return $true }
        }
    }

    # Some builds expose DV hints in tags/profile
    $prof = [string]$VideoStream.profile
    if ($prof -match "Dolby\s*Vision") { return $true }

    if ($VideoStream.tags) {
        foreach ($p in $VideoStream.tags.PSObject.Properties) {
            $k = [string]$p.Name
            $v = [string]$p.Value
            if ($k -match "dovi|dolby" -or $v -match "dovi|dolby\s*vision") { return $true }
        }
    }

    return $false
}

function Get-VideoSummary {
    param(
        [Parameter(Mandatory)] $ProbeJson,
        [Parameter(Mandatory)] $VideoStream
    )

    $codec = [string]$VideoStream.codec_name
    $w = TryParse-Int $VideoStream.width 0
    $h = TryParse-Int $VideoStream.height 0
    $pix = [string]$VideoStream.pix_fmt
    $hdr = (Test-Is10BitOrHDR $VideoStream)
    $dv  = (Test-IsDolbyVision -ProbeJson $ProbeJson -VideoStream $VideoStream)

    $bprs = TryParse-Int $VideoStream.bits_per_raw_sample 0
    if ($bprs -le 0 -and $pix -match "10le") { $bprs = 10 }

    return ("{0} {1}x{2} {3}bit pix={4} HDR={5} DV={6}" -f $codec,$w,$h,$bprs,$pix,([int]$hdr),([int]$dv))
}

function Get-AudioSummary {
    param([Parameter(Mandatory)] $ProbeJson)

    if (-not $ProbeJson.streams) { return "" }

    $aud = @($ProbeJson.streams | Where-Object { $_.codec_type -eq "audio" })
    if (-not $aud -or $aud.Count -eq 0) { return "NOAUDIO" }

    $parts = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($a in $aud) {
        $n++
        $codec = [string]$a.codec_name
        $ch = TryParse-Int $a.channels 0
        $br = TryParse-Int $a.bit_rate 0
        $brk = if ($br -gt 0) { [math]::Round($br/1000) } else { 0 }
        $lang = "und"
        if ($a.tags -and $a.tags.language) { $lang = Normalize-LanguageTag ([string]$a.tags.language) }
        $def = 0
        if ($a.disposition -and $a.disposition.default -eq 1) { $def = 1 }
        $parts.Add(("{0}:{1} {2}ch {3}k {4} def={5}" -f $n,$codec,$ch,$brk,$lang,$def)) | Out-Null
    }
    return ($parts -join " | ")
}

function Get-PrimaryAudioTrackNum {
    param([Parameter(Mandatory)] $ProbeJson)

    $aud = @($ProbeJson.streams | Where-Object { $_.codec_type -eq "audio" })
    if (-not $aud -or $aud.Count -eq 0) { return 0 }

    # Prefer default disposition
    for ($i=0; $i -lt $aud.Count; $i++) {
        if ($aud[$i].disposition -and $aud[$i].disposition.default -eq 1) { return ($i+1) }
    }

    # Otherwise: most channels, then bitrate
    $best = $aud | Sort-Object @{
        Expression={ TryParse-Int $_.channels 0 }; Descending=$true
    }, @{
        Expression={ TryParse-Int $_.bit_rate 0 }; Descending=$true
    } | Select-Object -First 1

    $idx = [array]::IndexOf($aud, $best)
    if ($idx -ge 0) { return ($idx+1) }
    return 1
}

function Get-BestAc3AudioTrackNum {
    param([Parameter(Mandatory)] $ProbeJson)

    $aud = @($ProbeJson.streams | Where-Object { $_.codec_type -eq "audio" })
    if (-not $aud -or $aud.Count -eq 0) { return 0 }

    $ac3 = @($aud | Where-Object { ([string]$_.codec_name) -eq "ac3" })
    if (-not $ac3 -or $ac3.Count -eq 0) { return 0 }

    $best = $ac3 | Sort-Object @{
        Expression={ TryParse-Int $_.channels 0 }; Descending=$true
    }, @{
        Expression={ TryParse-Int $_.bit_rate 0 }; Descending=$true
    } | Select-Object -First 1

    $idx = [array]::IndexOf($aud, $best)
    if ($idx -ge 0) { return ($idx+1) }
    return 1
}
