@echo off
:: Toggle voice services on/off
:: Checks Chatterbox (port 8890) to determine state (primary voice engine)
set "VOICE_DIR=%~dp0"
curl -sf http://127.0.0.1:8890/ >nul 2>&1
if %errorlevel% equ 0 (
    echo Stopping voice services...
    "C:\Program Files\Git\bin\bash.exe" -l -c "bash '%VOICE_DIR:\=/%start-all.sh' stop"
) else (
    echo Starting voice services...
    "C:\Program Files\Git\bin\bash.exe" -l -c "bash '%VOICE_DIR:\=/%start-all.sh' start"
)
