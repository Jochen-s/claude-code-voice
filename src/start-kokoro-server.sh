#!/usr/bin/env bash
# Start Kokoro TTS as OpenAI-compatible server on port 8880
# Serves: POST /v1/audio/speech
set -euo pipefail

# Resolve home to a path that works in both MINGW64 and native Windows
if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
PORT="${VOICEMODE_KOKORO_PORT:-8880}"

# Use the unified kokoro-venv (has both kokoro-onnx and fastapi/uvicorn)
venv="$SERVICES_DIR/kokoro-venv"
if [ ! -d "$venv" ]; then
  echo "Kokoro not installed. Run: bash setup-voice-services.sh --kokoro (from repo root)"
  exit 1
fi

source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

echo "Starting Kokoro TTS server on port $PORT..."
echo "Endpoint: http://127.0.0.1:$PORT/v1/audio/speech"
echo "Voices:   http://127.0.0.1:$PORT/v1/voices"

# Resolve the server script path (same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_SCRIPT="$SCRIPT_DIR/kokoro_server.py"

export KOKORO_PORT="$PORT"
exec python "$SERVER_SCRIPT"
