@echo off
:: Stop all voice services
set "VOICE_DIR=%~dp0"
"C:\Program Files\Git\bin\bash.exe" -l -c "bash '%VOICE_DIR:\=/%start-all.sh' stop"
