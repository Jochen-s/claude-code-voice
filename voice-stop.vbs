Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd.exe /c """ & Replace(WScript.ScriptFullName, "voice-stop.vbs", "voice-stop.bat") & """", 0, True
