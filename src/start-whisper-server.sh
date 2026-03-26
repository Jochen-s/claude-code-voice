#!/usr/bin/env bash
# Start faster-whisper as OpenAI-compatible server on port 2022
# Serves: POST /v1/audio/transcriptions
set -euo pipefail

# Resolve home to a path that works in both MINGW64 and native Windows
if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
PORT="${VOICEMODE_WHISPER_PORT:-2022}"
MODEL="${VOICEMODE_WHISPER_MODEL:-large-v3}"

venv="$SERVICES_DIR/whisper-venv"
if [ ! -d "$venv" ]; then
  echo "Whisper server not installed. Run: bash setup-voice-services.sh --whisper"
  exit 1
fi

source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

DEVICE="${VOICEMODE_WHISPER_DEVICE:-cuda}"
COMPUTE="${VOICEMODE_WHISPER_COMPUTE:-float16}"
LANGUAGE="${VOICEMODE_WHISPER_LANGUAGE:-en}"

echo "Starting faster-whisper STT server on port $PORT (model: $MODEL, device: $DEVICE, lang: $LANGUAGE)..."
echo "Endpoint: http://127.0.0.1:$PORT/v1/audio/transcriptions"

# Resolve the server script location (same directory as this launcher)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_SCRIPT="$SCRIPT_DIR/whisper_server.py"

if [ -f "$SERVER_SCRIPT" ]; then
  # Custom FastAPI server -- works on Python 3.14, replaces speaches
  exec python "$SERVER_SCRIPT" \
    --host 127.0.0.1 --port "$PORT" \
    --model "$MODEL" --device "$DEVICE" --compute-type "$COMPUTE" \
    --language "$LANGUAGE"
elif command -v speaches &>/dev/null; then
  # Fallback: speaches (requires Python <3.14)
  exec speaches --host 127.0.0.1 --port "$PORT" --model "$MODEL"
else
  echo "ERROR: No whisper server available."
  echo "Expected: $SERVER_SCRIPT or 'speaches' on PATH."
  exit 1
fi
