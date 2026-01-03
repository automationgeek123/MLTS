<#
media_config.ps1 (V71 - Sort Order Added)
Configuration file for the media automation suite.
#>

$MediaSuiteConfig = [ordered]@{

    # -----------------------------
    # TOOLING (executables)
    # -----------------------------
    Tools = [ordered]@{
        HandBrakeCli = "HandBrakeCLI.exe"
        Ffprobe      = "ffprobe.exe"
    }

    # -----------------------------
    # INPUT FILE TYPES
    # -----------------------------
    ValidExtensions = @(".mkv", ".mp4", ".avi", ".m4v", ".ts")

    # -----------------------------
    # LOGGING OUTPUT FILES
    # -----------------------------
    Logging = [ordered]@{
        ShrinkLogFile           = "shrink_log.csv"
        MissingAudioReportFile  = "missing_audio_report.csv"
        WrongLanguageReportFile = "wrong_language_report.csv"
    }

    # -----------------------------
    # SHRINK SETTINGS (Temp Path, etc.)
    # -----------------------------
    Shrink = [ordered]@{
        TempPath = ""
        ResourceMode = "Medium"
        RecentlyModifiedSkipMinutes = 15
        DolbyVisionPolicy = "RequirePreserve"
    }

    # -----------------------------
    # -----------------------------
    # VIDEO / ENCODER POLICY
    # -----------------------------
    Media = [ordered]@{
        # Backend: "auto", "qsv", "nvenc", "x265"
        EncoderBackend = "qsv"
        Preset         = "quality"
        Prefer10Bit    = "auto"

        # "Already good enough" thresholds (kbps)
        Threshold4K    = 8000
        Threshold1080  = 4000
        ThresholdSD    = 2000

        # Safe Language List (ISO 639-2/3)
        SafeLangs = @("eng", "und", "jpn") 

        # Target Bitrates for Estimation (kbps)
        Target4K   = 5000
        Target1080 = 2500
        
        # Encoding Speed Estimates (FPS) for Reports
        Speed4K    = 35
        Speed1080  = 200
    }

    # -----------------------------
    # BATCH EXECUTION SETTINGS
    # -----------------------------
    Batch = [ordered]@{
        TargetFolders = @()
        LockFileName  = "PAUSE.lock"

        # Sort Order Options: "SmallestFirst", "LargestFirst", "Alphabetical", "None"
        SortOrder = "SmallestFirst"

        # Night Mode Window (24h format).
        RunWindowStart = "23:00"
        RunWindowEnd   = "07:00"

        # Stop after processing N files (0 = unlimited)
        MaxFilesPerRun = 0

        # Filter to ignore files by name (e.g. trailers, samples)
        ExcludeNameRegex = "^hb_temp_|sample|trailer"

        # Drive scheduling strategy. Options: "PerfCounterLeastBusy", "Sequential"
        DriveSchedulingMode = "PerfCounterLeastBusy"

        SkipFilesNewerThanDays = 15
        CleanupTempOlderThanHours = 24
        MinFreeSpaceGB = 50
    }

    # -----------------------------
    # ESTIMATE TOOL (estimate_savings.ps1)
    # -----------------------------
    Estimate = [ordered]@{
        ScanPath     = "."
        MinSavingsMB = 50
        ReportFile   = "savings_report.csv"
        NoPause      = $false
    }

    # -----------------------------
    # SCAN: MISSING AUDIO (scan_missing_audio.ps1)
    # -----------------------------
    ScanMissingAudio = [ordered]@{
        ScanPath = "."
        NoPause  = $false
    }

    # -----------------------------
    # SCAN: WRONG LANGUAGE (scan_wrong_language.ps1)
    # -----------------------------
    ScanWrongLanguage = [ordered]@{
        ScanPath = "."
        LogFile  = "wrong_language_report.csv"
        StrictUnd = $false
        NoPause  = $false
    }
}

$MediaSuiteConfig