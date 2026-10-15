' Launches clipboard_sync_server.py fully hidden (no console window), output
' appended to clipboard_sync_server.log. Mirrors scripts,ahk monitor\launch-monitor.vbs.
Set objShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "cmd.exe /c cd /d """ & scriptDir & """ && python clipboard_sync_server.py >> clipboard_sync_server.log 2>&1"
objShell.Run cmd, 0, False
