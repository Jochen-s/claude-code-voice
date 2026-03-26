@echo off
:: Toggle voice services on/off
:: Checks if Qwen3-TTS (port 8880) is running to determine state
set "VOICE_DIR=%~dp0"
curl -sf http://127.0.0.1:8880/health >nul 2>&1
if %errorlevel% equ 0 (
    echo Stopping voice services...
    "C:\Program Files\Git\bin\bash.exe" -l -c "bash '%VOICE_DIR:\=/%start-all.sh' stop"
) else (
    echo Starting voice services...
    "C:\Program Files\Git\bin\bash.exe" -l -c "bash '%VOICE_DIR:\=/%start-all.sh' start"
)
