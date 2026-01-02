Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

CurrentDir = fso.GetParentFolderName(WScript.ScriptFullName)
ScriptPath = fso.BuildPath(CurrentDir, "run_batch_job.ps1")

cmd = "powershell.exe -NoProfile -NonInteractive -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ScriptPath & """"
WshShell.Run cmd, 0

Set WshShell = Nothing
