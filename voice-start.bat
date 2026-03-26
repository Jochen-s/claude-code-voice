@echo off
:: Start all voice services (TTS + STT)
:: Adjust VOICE_DIR to your clone location
set "VOICE_DIR=%~dp0"
"C:\Program Files\Git\bin\bash.exe" -l -c "bash '%VOICE_DIR:\=/%start-all.sh' start"
