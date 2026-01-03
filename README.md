
```markdown
# Media Fix – Automated Video Optimization Suite

Media Fix is a PowerShell-based automation suite for **analyzing, optimizing, and maintaining large media libraries** (movies/TV). It prioritizes **safety, determinism, and auditability** over raw speed.

**Current Status:** Production Stable (Strict Mode Compatible)

## Key Features

* **Space Saving:** Transcodes bloated files to efficient HEVC (x265/QSV/NVENC).
* **Safety First:**
    * **Atomic Swaps:** Original files are never deleted until the new file is verified.
    * **Root Protection:** Refuses to process or write files in drive roots (e.g., `D:\`).
    * **Free Space Guard:** Pauses execution if disk space drops below a threshold (default 50GB).
* **Smart Automation:**
    * **Night Mode:** Restricts processing to specific hours (e.g., 23:00–07:00).
    * **Least-Busy Scheduling:** Dynamically picks files from the drive with the least I/O load.
    * **Queue Sorting:** Processes files Smallest-First, Largest-First, or Alphabetically.
* **Reporting:**
    * **Savings Estimator:** Predicts space savings without modifying files.
    * **Audio/Lang Scanners:** Finds silent files or foreign-language-only tracks.

---

## Repository Structure

| File | Role |
| :--- | :--- |
| `run_batch_job.ps1` | **The Controller.** Scans drives, builds queues, and manages the worker loop. |
| `shrink_execute.ps1` | **The Worker.** Processes one file at a time (runs hidden). |
| `media_common.ps1` | **The Library.** Shared helpers, logging, and robust config loaders. |
| `media_config.ps1` | **Defaults.** The safe, base configuration (tracked in Git). |
| `media_user_settings.json` | **User Config.** Your local paths/settings (generated on first run). |
| `estimate_savings.ps1` | **Report:** Scans your library and calculates potential savings. |
| `scan_missing_audio.ps1` | **Report:** Finds files with 0 audio streams. |
| `scan_wrong_language.ps1` | **Report:** Finds files where the default track isn't in your "Safe List". |
| `silent_boot.vbs` | **Launcher:** Runs the batch job completely in the background. |

---

## Quick Start

### 1. First Run (Interactive Setup)
Open PowerShell in the script folder and run:
```powershell
.\run_batch_job.ps1

```

The script will detect that `media_user_settings.json` is missing and launch a **setup wizard**. You will be asked for:

1. **Target Folders:** Where your media lives (e.g., `G:\English TV`).
2. **Tool Paths:** Location of `HandBrakeCLI.exe` and `ffprobe.exe`.
3. **Temp Path:** Dedicated SSD for transcoding (optional).
4. **Resource Mode:** Process priority (`Light`, `Medium`, `Heavy`).

### 2. Routine Execution

Just run `.\run_batch_job.ps1` again.

* It will load your settings.
* It will scan for files.
* It will start processing files **silently in the background**.
* **Note:** The main window stays open to show progress ("Processing [G]: Movie.mkv"), but the heavy lifting happens in a hidden process.

### 3. Background / Scheduled Task

Use `silent_boot.vbs` to run the entire suite hidden (no window at all). Ideal for Windows Task Scheduler.

---

## Configuration

### `media_user_settings.json`

This file controls your local environment. You can edit it manually to tweak advanced settings.

**Example `Batch` Block:**

```json
"Batch": {
    "TargetFolders": [
        "G:\\English TV",
        "H:\\Movies"
    ],
    "SortOrder": "SmallestFirst",       // Options: SmallestFirst, LargestFirst, Alphabetical
    "RunWindowStart": "23:00",          // Start time (24h)
    "RunWindowEnd": "07:00",            // End time
    "MinFreeSpaceGB": 50,               // Pause if destination has less space
    "ExcludeNameRegex": "^sample|trailer", // Skip files matching this regex
    "SkipFilesNewerThanDays": 15        // Don't touch files added recently
}

```

### `media_config.ps1`

Contains technical defaults like bitrate targets and safe languages.

* **Media Targets:** `Target1080 = 2500` (kbps target for savings estimation).
* **Safe Languages:** `SafeLangs = @("eng", "und", "jpn")`.

---

## Reports & Analysis

The reporting tools are now "Batch Aware." If you run them without arguments, they automatically scan the folders defined in your `media_user_settings.json`.

### 1. Savings Estimator

Calculates how much space you *could* save based on your bitrate targets.

```powershell
.\estimate_savings.ps1

```

* **Output:** `savings_report.csv`
* **Logic:** Aggregates all target folders into one list.

### 2. Missing Audio Scan

Finds files that might be corrupted (video exists, but audio track count is 0).

```powershell
.\scan_missing_audio.ps1

```

* **Output:** `missing_audio_report.csv`

### 3. Wrong Language Scan

Flags files where the **default** audio track is not in your `SafeLangs` list (e.g., a movie defaulting to French commentary).

```powershell
.\scan_wrong_language.ps1

```

* **Output:** `wrong_language_report.csv`

---

## Log Files

All transcoding activity is logged to `shrink_log.csv`. This file is locked safely, so you can open it in Excel/Notepad while the script runs.

**Key Columns:**

* **Strategy:** Why the file was picked (e.g., "Upgrade (h264)", "4K Bloat").
* **Status:** Outcome (`Success`, `Skipped-Efficient`, `Failed-HandBrake`, `Skipped-LowSpace`).
* **Saved_MB:** Space reclaimed.
* **Encode10:** `1` if 10-bit encoding was used (for HDR/DV preservation).

---

## Safety Mechanisms

1. **Strict Mode Compliance:** All scripts run under `Set-StrictMode -Version Latest` to prevent silent variable errors.
2. **Null-Safe Config:** Uses robust accessors (`Get-Cfg`) to prevent crashes if a setting is missing.
3. **Root Path Block:** The worker will **immediately exit** if asked to write to a drive root (e.g., `G:\hb_temp_...`), preventing accidental mass deletion risks.
4. **Verification Loop:** After encoding, the new file is probed 3 times. It must pass duration, stream count, and codec checks before the original is replaced.

---

## Technical Details

* **Dolby Vision:** Preserved if `DolbyVisionPolicy` is set to `RequirePreserve`. If the output loses metadata, the swap is aborted.
* **Hardware Acceleration:** Supports `Intel QSV` (default), `NVIDIA NVENC`, and `CPU (x265)`. Auto-detects capabilities.
* **Logging:** Uses a retry-backoff mechanism to write to CSVs even if they are momentarily locked by another process.

---

*Use at your own risk. Always test on a small folder first.*

```

```