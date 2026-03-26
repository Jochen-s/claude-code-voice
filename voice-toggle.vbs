Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd.exe /c """ & Replace(WScript.ScriptFullName, "voice-toggle.vbs", "voice-toggle.bat") & """", 0, True
