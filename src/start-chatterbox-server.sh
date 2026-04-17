#!/usr/bin/env bash
# Start Chatterbox TTS as OpenAI-compatible server on port 8890
# Serves: POST /v1/audio/speech (voice cloning, emotion control)
set -euo pipefail

if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
REPO_DIR="$SERVICES_DIR/chatterbox"
PORT="${VOICEMODE_CHATTERBOX_PORT:-8890}"

venv="$REPO_DIR/.venv"
if [ ! -d "$venv" ]; then
  echo "Chatterbox not installed. Run: bash src/setup-chatterbox.sh (from repo root)"
  exit 1
fi

source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"
cd "$REPO_DIR"

echo "Starting Chatterbox TTS server on port $PORT..."
echo "Endpoint:  http://127.0.0.1:$PORT/v1/audio/speech"
echo "Full TTS:  http://127.0.0.1:$PORT/tts"
echo "Docs:      http://127.0.0.1:$PORT/docs"

# Suppress automatic browser opening (no CLI flag available)
export BROWSER=echo

exec python server.py
