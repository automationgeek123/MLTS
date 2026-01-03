<#
media_config.ps1
Configuration file for the media automation suite.

How it works
- Each script dot-sources media_common.ps1, which loads THIS file on every run.
- Changing values here affects the next run immediately (no script edits needed).
- You can use absolute paths, or paths relative to the script folder.

Notes
- Strings are in quotes.
- Booleans use $true / $false.
- Lists use @( "a", "b" ).
- To disable a feature, follow the parameter’s comment.

#>

$MediaSuiteConfig = [ordered]@{

    # -----------------------------
    # TOOLING (executables)
    # -----------------------------
    Tools = [ordered]@{
        # HandBrakeCLI path. Recommended: keep HandBrakeCLI.exe beside the scripts.
        # Options:
        #   - "HandBrakeCLI.exe"            (relative to script folder)
        #   - "C:\Tools\HandBrakeCLI.exe"   (absolute)
        HandBrakeCli = "HandBrakeCLI.exe"

        # ffprobe path (from FFmpeg). Recommended: keep ffprobe.exe beside the scripts.
        # Options:
        #   - "ffprobe.exe"
        #   - "C:\Tools\ffprobe.exe"
        Ffprobe = "ffprobe.exe"
    }

    # -----------------------------
    # INPUT FILE TYPES
    # -----------------------------
    # Extensions to include when scanning folders.
    # IMPORTANT: include the leading dot, and keep them lowercase.
    ValidExtensions = @(".mkv", ".mp4", ".avi", ".m4v", ".ts")

    # -----------------------------
    # LOGGING OUTPUT FILES
    # -----------------------------
    Logging = [ordered]@{
        # Main shrink log written by shrink_execute.ps1 and run_batch_job.ps1.
        # Relative paths are created in the script folder.
        ShrinkLogFile = "shrink_log.csv"

        # Report output for scan_missing_audio.ps1
        MissingAudioReportFile = "missing_audio_report.csv"

        # Report output for scan_wrong_language.ps1
        WrongLanguageReportFile = "wrong_language_report.csv"
    }

    # -----------------------------
    # VIDEO / ENCODER POLICY
    # -----------------------------
    Media = [ordered]@{
        # Which encoder backend to use.
        # Options:
        #   - "auto"  : detect Intel/NVIDIA and pick QSV/NVENC when available, else CPU x265
        #   - "qsv"   : force Intel QuickSync (requires Intel iGPU + drivers)
        #   - "nvenc" : force NVIDIA NVENC (requires NVIDIA GPU + drivers)
        #   - "x265"  : force CPU x265 (slowest but most compatible)
        EncoderBackend = "qsv"

        # HandBrake encoder preset.
        # Typical options (varies by encoder): ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
        # Your current suite expects "quality" style behavior; keep this unless you know your encoder supports the name.
        Preset = "quality"

        # 10-bit decision policy.
        # Options:
        #   - "auto"   : use 10-bit only when source is 10-bit or HDR (recommended)
        #   - "always" : always encode 10-bit
        #   - "never"  : always encode 8-bit
        Prefer10Bit = "auto"

        # "Already good enough" thresholds (kbps).
        # If a file is already HEVC and its bitrate is at/below these thresholds, it will be skipped.
        Threshold4K   = 8000
        Threshold1080 = 4000

        # Target video bitrates (kbps) used by estimate_savings.ps1.
        Target4K      = 5000
        Target1080    = 2500

        # Estimated processing speed (frames/sec) used by estimate_savings.ps1 for ETA.
        # Calibrate with your own machine to make ETAs useful.
        Speed4K       = 35
        Speed1080     = 200

        # Languages considered "acceptable" for scans (used by scan_wrong_language.ps1).
        # Keep "und" if you want to treat unknown as acceptable.
        SafeLangs     = @("eng","en","hin","hi","und")

        # -----------------------------
        # AUDIO POLICY (for optical output)
        # -----------------------------
        # The suite prefers an AC3 track to exist and be first, so Emby/TV optical output is consistent.
        # When AC3 does not exist, it creates an AC3 track from the primary track.
        #
        # AC3 bitrates (kbps). These are used only when a new AC3 track is created.
        # Common values:
        #   - 5.1: 640 (best), 448 (smaller)
        #   - 2.0: 256 (good), 192 (smaller)
        Ac3BitrateK_51 = 640
        Ac3BitrateK_20 = 256
    }

    # -----------------------------
    # SHRINK WORKER (shrink_execute.ps1)
    # -----------------------------
    Shrink = [ordered]@{
        # Default scan path when you run shrink_execute.ps1 manually.
        # Can be a folder or a single file.
        ScanPath = "."

        # Temporary output directory.
        # Options:
        #   - ""  : use the source file's folder (default)
        #   - "D:\Temp\HandBrake" : use a dedicated temp drive (recommended if you want max reliability)
        TempPath = ""

        # Minimum savings required to replace the original (MB).
        # If savings are less than this, the original is kept.
        MinSavingsMB = 512

        # If $true, attempts re-encoding even when the file looks already efficient.
        Force = $false

        # If $true, do not show or honor PAUSE.lock behavior.
        # Recommended $true for scheduled runs.
        NoPause = $true

        # Dry-run mode: scans + logs but does not encode/replace.
        WhatIf = $false

        # Process priority:
        #   - $false: set to Idle (recommended if you use the PC while encoding)
        #   - $true : leave default priority
        NormalPriority = $false

        # Skip files modified within the last N minutes (prevents encoding files still downloading/copying).
        # Set to 0 to disable.
        RecentlyModifiedSkipMinutes = 15
    }

    # -----------------------------
    # BATCH CONTROLLER (run_batch_job.ps1)
    # -----------------------------
    Batch = [ordered]@{
        # List of folders to process (recursive).
        # NOTE: You can leave this empty and let run_batch_job.ps1 prompt you on first run.
        # The chosen folders are saved to media_user_settings.json and reused automatically.
        TargetFolders = @()

        # Lock file name used to pause batch runs.
        # If this file exists in the script folder, the batch waits.
        LockFileName = "PAUSE.lock"

        # Skip files newer than N days (batch-level filter). 0 disables.
        SkipFilesNewerThanDays = 15

        # Cleanup any leftover temp files older than N hours. 0 disables.
        CleanupTempOlderThanHours = 24
    }

    # -----------------------------
    # ESTIMATE TOOL (estimate_savings.ps1)
    # -----------------------------
    Estimate = [ordered]@{
        ScanPath = "."
        MinSavingsMB = 50

        # Optional: save estimate output to a CSV file.
        # "" means "do not write a file".
        ReportFile = ""
        NoPause = $false
    }

    # -----------------------------
    # SCAN: MISSING AUDIO (scan_missing_audio.ps1)
    # -----------------------------
    ScanMissingAudio = [ordered]@{
        ScanPath = "."
        NoPause = $false
    }

    # -----------------------------
    # SCAN: WRONG LANGUAGE (scan_wrong_language.ps1)
    # -----------------------------
    ScanWrongLanguage = [ordered]@{
        ScanPath = "."

        # If $true, "und" (unknown language) is treated as NOT acceptable.
        # If $false, "und" is allowed if it exists in Media.SafeLangs.
        StrictUnd = $false

        NoPause = $false
    }
}

# Return the hashtable so media_common.ps1 can merge it with defaults.
$MediaSuiteConfig
