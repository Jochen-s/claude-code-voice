Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd.exe /c """ & Replace(WScript.ScriptFullName, "voice-start.vbs", "voice-start.bat") & """", 0, True
