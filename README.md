# Media Fix – Automated Video Optimization Suite

Media Fix is a PowerShell-based automation suite for **analyzing, optimizing, and maintaining large media libraries** (movies/TV) with a strong focus on **safety, determinism, and auditability**.

It is designed to:
- Reduce storage usage by transcoding inefficient video files
- Preserve quality (HEVC, 10-bit, HDR, Dolby Vision when possible)
- Avoid corrupting or partially downloaded files
- Run unattended (scheduled / background) with clear logging and pop-ups for critical issues

---

## Key Design Principles

- **Never destroy data silently**
- **Log everything**
- **Make all decisions deterministic and configurable**
- **Separate defaults (repo) from user-specific settings (local only)**

---

## Repository Structure

```

media_common.ps1              # Shared helpers, logging, ffprobe parsing
media_config.ps1              # GitHub-safe default configuration (edit this)
run_batch_job.ps1             # Main batch controller
shrink_execute.ps1            # Worker: processes one file at a time
scan_missing_audio.ps1        # Report: files with no audio streams
scan_wrong_language.ps1       # Report: files with unknown default audio language
estimate_savings.ps1          # Report: size/codec inventory (no transcoding)
silent_boot.vbs               # Optional background launcher
media_user_settings.example.json
.gitignore
README.md

```

---

## How Configuration Works

### 1. `media_config.ps1` (Tracked in Git)
- Contains **safe defaults**
- No personal paths or folders
- Reloaded on every run
- Edit this to change global behavior

### 2. `media_user_settings.json` (Generated Locally)
- Created on **first run**
- Stores **machine-specific values**:
  - Media folders
  - Tool paths (HandBrakeCLI / ffprobe)
  - Temp folder
  - Resource mode
- Automatically reused on future runs
- **Ignored by Git** (see `.gitignore`)

**Merge order (highest priority wins):**
```

media_config.ps1  →  media_user_settings.json

````

---

## First-Run Setup (Interactive)

When you run:

```powershell
.\run_batch_job.ps1
````

for the first time, you will be prompted for:

1. **Folders to scan**

   * One per line
   * Blank line to finish

2. **HandBrakeCLI.exe path**

   * Press Enter if it is in the same folder or in PATH

3. **ffprobe.exe path**

   * Press Enter if it is in the same folder or in PATH

4. **Transcode temp folder**

   * Press Enter to use the **source file’s folder**
   * Or specify a separate drive/folder

5. **Resource mode**

   * `Light`, `Medium`, or `Heavy`
   * Controls HandBrake **process priority only**

6. **Skip recently modified files**

   * Minutes to skip files still being copied/downloaded

7. **Optional: age filter**

   * Only process files older than N days (0 disables)

These values are saved to `media_user_settings.json` and reused automatically.

---

## Running in Background

Use:

```powershell
silent_boot.vbs
```

Behavior:

* If `media_user_settings.json` **does not exist** → runs **visible**
* If it **exists** → runs **hidden**
* Pop-ups will still appear for critical issues

Ideal for Task Scheduler or Startup execution.

---

## Dolby Vision (DV) Policy

Dolby Vision handling is **explicit and deterministic**.

### Config key

```powershell
Shrink.DolbyVisionPolicy =
  Skip |
  RequirePreserve |
  TranscodeAllowLoss
```

### Meanings

| Policy                        | Behavior                                              |
| ----------------------------- | ----------------------------------------------------- |
| **Skip**                      | If input is Dolby Vision → do not transcode           |
| **RequirePreserve** (default) | Transcode DV → **replace only if output is still DV** |
| **TranscodeAllowLoss**        | Transcode DV and replace even if DV metadata is lost  |

DV presence is detected via:

* `dvh1` / `dvhe` codec tags
* ffprobe `side_data_list` (DOVI)

DV status is logged for both input and output.

---

## Run Window (Night Mode)

Configured in `media_config.ps1`:

```powershell
Batch.RunWindowStart = "23:00"
Batch.RunWindowEnd   = "07:00"
```

Behavior:

* If current time is **inside** the window → runs immediately
* If **outside** the window:

  * Popup appears:

    * **YES** → run now
    * **NO** → wait until window opens
  * If waiting, script sleeps and **starts automatically** at window start

Cross-midnight windows are fully supported.

---

## Drive Scheduling (Least Busy Drive)

When enabled:

```powershell
Batch.DriveSchedulingMode = "PerfCounterLeastBusy"
```

* Files are grouped by **source drive**
* Before each file is picked, Windows Performance Counters are sampled:

  * `\LogicalDisk(X:)\% Disk Time`
* The **least busy drive at that moment** is selected
* Counters are re-checked **for every pick**

Fallback:

* If counters fail → folder order is used

---

## Low Disk Space Handling

Configured by:

```powershell
Batch.MinFreeSpaceGB = 50
```

Before starting an encode:

* Free space is checked on the **output/work drive**
* If below threshold:

  * Popup appears:

    * **YES** → skip this drive for the rest of the run
    * **NO** → stop immediately
* Skip decision applies **only to the current run**

All events are logged.

---

## Resource Modes

```powershell
Shrink.ResourceMode = Light | Medium | Heavy
```

Controls **HandBrake process priority only**:

| Mode   | Priority    |
| ------ | ----------- |
| Light  | BelowNormal |
| Medium | Normal      |
| Heavy  | AboveNormal |

No CPU pinning, no concurrency changes.

---

## Exclude Patterns

```powershell
Batch.ExcludeNameRegex = '^hb_temp_|sample|trailer'
```

Applied to **file name only** (not full path).

Used to avoid:

* Temporary outputs
* Samples
* Trailers
* Extras

---

## Max Files per Run

```powershell
Batch.MaxFilesPerRun = 0
```

* `0` → unlimited
* `N > 0` → stop after N files

Useful for scheduled incremental runs.

---

## Logging

All activity is written to:

```
shrink_log.csv
```

Schema is fixed and enforced.

Key fields:

* `Strategy` – why the file was selected
* `Status` – outcome (`Success`, `Skipped-*`, `Fail-*`)
* `Detail` – human-readable explanation
* `OrigVideo` / `NewVideo`
* `OrigAudio` / `NewAudio`
* `OrigDV` / `NewDV`
* `Encode10`

This file is safe to open while the script is running.

---

## Failure Popups

Popups appear **only for fatal conditions**, configured by:

```powershell
Batch.PopupFatalStatusRegex
```

Defaults include:

* Worker crashes
* Encode failures
* DV preservation failures
* Low-space stops

Non-fatal skips do **not** popup.

---

## Safety Guarantees

* Originals are backed up as `.bak` during replace
* `.bak` files are restored automatically if a failure occurs
* Temp files are cleaned up
* Recently modified files are skipped
* No overwrite happens without validation

---

## Typical Usage

### One-time setup

```powershell
.\run_batch_job.ps1
```

### Scheduled nightly run

* Use `silent_boot.vbs`
* Set Task Scheduler trigger

### Reports only

```powershell
.\scan_missing_audio.ps1
.\scan_wrong_language.ps1
.\estimate_savings.ps1
```

---

## License / Use

This project is provided as-is.
Test on a small subset before running against a full library.

---

## Final Notes

This suite is intentionally conservative.
If a decision is ambiguous, it will **skip or stop rather than guess**.

That’s by design.

```
