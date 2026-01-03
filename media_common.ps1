# --- media_common.ps1 (V77 - Silent Failure Fixes) ---
# Shared configuration + robust helpers.
# FIX: Centralized Get-Cfg with defensive null checks.
# FIX: Added logging to empty catch blocks (no more silent failures).
# FIX: Corrected Get-ChildItem syntax in cleanup logic.

Set-StrictMode -Version Latest

$Global:ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Global:ToolsDir)) { $Global:ToolsDir = "." }

# --- 1) CONFIG LOADER ---
$ConfigFile = Join-Path $Global:ToolsDir "media_config.ps1"
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Missing config file: $ConfigFile" }
$Global:MediaConfig = . $ConfigFile

function Merge-Config {
    param($Target, $Source)
    if (-not $Source) { return }
    $keys = if ($Source -is [System.Collections.IDictionary]) { $Source.Keys } else { $Source.PSObject.Properties.Name }
    foreach ($key in $keys) {
        $sourceVal = if ($Source -is [System.Collections.IDictionary]) { $Source[$key] } else { $Source.$key }
        if ($Target.Contains($key)) {
            $targetVal = $Target[$key]
            $targetIsDict = ($targetVal -is [System.Collections.IDictionary])
            $sourceIsDict = ($sourceVal -is [System.Collections.IDictionary] -or $sourceVal -is [System.Management.Automation.PSCustomObject])
            if ($targetIsDict -and $sourceIsDict) { Merge-Config -Target $targetVal -Source $sourceVal }
            else { $Target[$key] = $sourceVal }
        }
    }
}

$UserFile = Join-Path $Global:ToolsDir "media_user_settings.json"
if (Test-Path -LiteralPath $UserFile) {
    try {
        $UserJson = Get-Content -LiteralPath $UserFile -Raw -ErrorAction Stop | ConvertFrom-Json
        Merge-Config -Target $Global:MediaConfig -Source $UserJson
    } catch { Write-Warning "Failed to load settings: $_" }
}

# --- 2) ROBUST CONFIG HELPER (NEW) ---
function Get-Cfg { 
    param($Key1, $Key2)
    # Defensive Check: Return null if config isn't loaded yet
    if ($null -eq $Global:MediaConfig) { return $null }
    
    if ($Global:MediaConfig.Contains($Key1)) {
        $k1 = $Global:MediaConfig[$Key1]
        if ($k1 -is [System.Collections.IDictionary] -and $k1.Contains($Key2)) { 
            return $k1[$Key2] 
        }
    }
    return $null
}

# Strict Access using helper where possible, or direct index for known keys
$Global:HbPath = Get-Cfg "Tools" "HandBrakeCli"
if (-not $Global:HbPath) { $Global:HbPath = "HandBrakeCLI.exe" }
if (-not [System.IO.Path]::IsPathRooted($Global:HbPath)) { $Global:HbPath = Join-Path $Global:ToolsDir $Global:HbPath }

$Global:FfPath = Get-Cfg "Tools" "Ffprobe"
if (-not $Global:FfPath) { $Global:FfPath = "ffprobe.exe" }
if (-not [System.IO.Path]::IsPathRooted($Global:FfPath)) { $Global:FfPath = Join-Path $Global:ToolsDir $Global:FfPath }

$Global:ValidExtensions = $Global:MediaConfig['ValidExtensions']

# --- 3) LOGGING ---
$Global:ShrinkLogColumns = @("Date","InputPath","OutputPath","Strategy","Old_MB","New_MB","Saved_MB","Status","Detail","OrigVideo","NewVideo","OrigAudio","NewAudio","OrigDV","NewDV","Encode10","AudioPlan")

function Write-MediaLog {
    param([string]$InputPath, [string]$OutputPath="-", [string]$Strategy="None", [double]$Old_MB=0, [double]$New_MB=0, [double]$Saved_MB=0, [string]$Status, [string]$Detail="", [string]$OrigVideo="", [string]$NewVideo="", [string]$OrigAudio="", [string]$NewAudio="", [int]$OrigDV=0, [int]$NewDV=0, [int]$Encode10=0, [string]$AudioPlan="")
    
    $LogFile = Get-Cfg "Logging" "ShrinkLogFile"
    if (-not $LogFile) { $LogFile = "shrink_log.csv" }
    
    $LogPath = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $Global:ToolsDir $LogFile }
    
    $Payload = [pscustomobject]@{ Date=(Get-Date).ToString('yyyy-MM-dd HH:mm'); InputPath=$InputPath; OutputPath=$OutputPath; Strategy=$Strategy; Old_MB=$Old_MB; New_MB=$New_MB; Saved_MB=$Saved_MB; Status=$Status; Detail=$Detail; OrigVideo=$OrigVideo; NewVideo=$NewVideo; OrigAudio=$OrigAudio; NewAudio=$NewAudio; OrigDV=$OrigDV; NewDV=$NewDV; Encode10=$Encode10; AudioPlan=$AudioPlan } | Select-Object $Global:ShrinkLogColumns
    
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try { $Payload | Export-Csv -Path $LogPath -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop; break }
        catch { Start-Sleep -Milliseconds (Get-Random -Min 500 -Max 2000) }
    }
}

# --- 4) HARDWARE ---
$Global:EncoderName = "CPU"
$EncoderArgs8 = @("-e","x265")
$EncoderArgs10 = @("-e","x265_10bit")

try {
    $backend = Get-Cfg "Media" "EncoderBackend"
    if ($backend -eq "auto") { $backend = "x265" }
    switch ($backend) {
        "qsv" { 
            $Global:EncoderName = "QSV"
            $EncoderArgs8 = @("-e","qsv_h265")
            $EncoderArgs10 = @("-e","qsv_h265_10bit") 
        }
        "nvenc" { 
            $Global:EncoderName = "NVENC"
            $EncoderArgs8 = @("-e","nvenc_h265")
            $EncoderArgs10 = @("-e","nvenc_h265_10bit") 
        }
    }
} catch { Write-Warning "Hardware Detection Failed: $_" }

$Global:MediaConfig['Media']["EncoderArgs8"] = $EncoderArgs8
$Global:MediaConfig['Media']["EncoderArgs10"] = $EncoderArgs10

# --- 5) HELPERS ---
function Get-JsonProp { 
    param($Obj, [string]$PropName, $Default=$null) 
    if($null -eq $Obj){return $Default} 
    if($Obj.PSObject.Properties.Match($PropName).Count){return $Obj.$PropName} 
    return $Default 
}

function Show-Popup { 
    param($Text, $Title="Media", $Timeout=0, $Buttons="YesNo") 
    try { (New-Object -Com WScript.Shell).Popup($Text, $Timeout, $Title, 4132) } catch { return -1 } 
}

function Test-MediaTools { 
    if(-not (Test-Path -LiteralPath $Global:HbPath)){throw "HandBrake missing at $Global:HbPath"}
    if(-not (Test-Path -LiteralPath $Global:FfPath)){throw "FFprobe missing at $Global:FfPath"} 
}

function Invoke-FfprobeJson { 
    param($Path, $ArgsList) 
    try { 
        $a = @("-v","error","-print_format","json") + $ArgsList + @("--", $Path)
        $j = & $Global:FfPath @a 2>$null
        if($j){return $j|ConvertFrom-Json} 
    } catch {
        # FIX: Log failure instead of staying silent
        Write-Warning "Ffprobe failed on '$Path': $($_.Exception.Message)"
    } 
    return $null 
}

function TryParse-Double { 
    param($v, $d=0.0) 
    if([double]::TryParse($v, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)){return $d} 
    return $d 
}

function TryParse-Int { 
    param($v, $d=0) 
    $i=0; if([int]::TryParse($v, [ref]$i)){return $i} 
    return $d 
}

function Get-RealFps { 
    param($s) 
    $fps=0.0
    if($s){ $r=Get-JsonProp $s "avg_frame_rate"; if($r -match '(\d+)/(\d+)'){ $fps=[double]$Matches[1]/[double]$Matches[2] } }
    if($fps -le 0){ $fps=24.0 }
    return $fps 
}

function Normalize-LanguageTag { 
    param([string]$l) 
    if([string]::IsNullOrWhiteSpace($l)){return "und"} 
    $p = $l.Trim().ToLower().Split([char[]]@('-', '_'))
    if($p.Count -gt 0){return $p[0]} return $l 
}

function Resolve-ScanPath { 
    param($p) 
    if([string]::IsNullOrWhiteSpace($p)){$p="."} 
    # Use LiteralPath to support brackets []
    if(-not (Test-Path -LiteralPath $p)){throw "Path not found: $p"} 
    return (Resolve-Path -LiteralPath $p).Path 
}

function Get-PathFreeSpace { 
    param($p) 
    try{ $r=[IO.Path]::GetPathRoot($p); $d=Get-PSDrive|?{$r -like "$($_.Name):*"}; if($d){return $d.Free} return 0 } 
    catch { 
        Write-Warning "Space Check Failed for '$p': $_"; return 0 
    } 
}

function Get-PrimaryVideoStream { 
    param($json)
    if (-not $json) { return $null }
    $s = Get-JsonProp $json "streams"
    if (-not $s) { return $null }
    
    $streams = @($s)
    $c = @($streams | ? { $_.codec_type -eq "video" -and -not ($_.disposition -and $_.disposition.attached_pic -eq 1) })
    
    if($c.Count -eq 0){ 
        return ($streams | ? {$_.codec_type -eq "video"} | Select -First 1) 
    }
    return ($c | Sort { (TryParse-Int $_.width)*(TryParse-Int $_.height) } -Descending | Select -First 1)
}

function Test-Is10BitOrHDR { 
    param($v) 
    $p=[string](Get-JsonProp $v "pix_fmt")
    $pr=[string](Get-JsonProp $v "profile")
    return ($p -match "10le" -or $pr -match "Main 10") 
}

function Test-IsDolbyVision {
    param($j, $v)
    if (-not $v) { return $false }
    $tag = [string](Get-JsonProp $v "codec_tag_string")
    if ($tag -match "^(dvh1|dvhe)$") { return $true }
    $sides = Get-JsonProp $v "side_data_list"
    if ($sides -and $sides -is [System.Collections.IEnumerable]) {
        foreach ($side in $sides) {
            $type = [string](Get-JsonProp $side "side_data_type")
            if ($type -match "Dolby Vision") { return $true }
        }
    }
    return $false
}

function Get-VideoSummary {
    param($j, $v) 
    if(-not $v){return "N/A"}
    $res = "$([string]$v.width)x$([string]$v.height)"
    $br = TryParse-Double (Get-JsonProp $v "bit_rate") 0
    if($br -le 0 -and $j){ 
        $fmt = Get-JsonProp $j "format"
        if ($fmt) {
            $d = TryParse-Double (Get-JsonProp $fmt "duration") 0
            $sz = TryParse-Double (Get-JsonProp $fmt "size") 0
            if($d -gt 0){ $br = ($sz*8)/$d }
        }
    }
    return "$([string]$v.codec_name) $res $([math]::Round($br/1000))k"
}

function Get-AudioSummary { 
    param($j) 
    $s=@()
    $streams = Get-JsonProp $j "streams"
    if ($streams) {
        foreach($a in $streams){
            if($a.codec_type -eq "audio"){$s+=([string]$a.codec_name)}
        } 
    }
    return ($s -join "|") 
}

function Get-PrimaryAudioTrackNum { 
    param($j)
    $streams = Get-JsonProp $j "streams"
    if ($streams) {
        foreach($s in $streams){
            if($s.codec_type -eq "audio" -and $s.disposition -and $s.disposition.default -eq 1){return $s.index+1}
        }
    }
    return 1 
}

function Get-BestAc3AudioTrackNum { 
    param($j) 
    $b=0;$bs=0; 
    $streams = Get-JsonProp $j "streams"
    if ($streams) {
        foreach($s in $streams){
            if($s.codec_type -eq "audio" -and $s.codec_name -match "ac3"){ 
                $sc=10; if($s.channels -ge 6){$sc=20} 
                if($sc -gt $bs){$bs=$sc; $b=$s.index+1}
            }
        } 
    }
    return $b 
}

function Invoke-Cleanup {
    $t = Get-Cfg "Shrink" "TempPath"
    if (-not [string]::IsNullOrWhiteSpace($t) -and (Test-Path -LiteralPath $t)) {
        # FIX: Use correct syntax: -Path for folder, -Filter for pattern
        Get-ChildItem -Path $t -Filter "hb_temp_*.mkv" -File -ErrorAction SilentlyContinue | 
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-24) } | 
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}