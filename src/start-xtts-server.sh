#!/usr/bin/env bash
# Start Coqui XTTS-v2 server for character voice cloning on port 8890
# GPU-accelerated via CUDA (RTX 5090)
set -euo pipefail

# Resolve home to a path that works in both MINGW64 and native Windows
if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
PORT="${XTTS_PORT:-8890}"
VOICES_DIR="$WIN_HOME/.claude/voices"

venv="$SERVICES_DIR/xtts-venv"
if [ ! -d "$venv" ]; then
  echo "XTTS not installed. Run: bash src/setup-xtts.sh (from repo root)"
  exit 1
fi

source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

echo "Starting XTTS-v2 server on port $PORT..."
echo "Voices directory: $VOICES_DIR"
echo ""
echo "Available voice profiles:"
for wav in "$VOICES_DIR"/*.wav; do
  [ -f "$wav" ] && echo "  - $(basename "$wav" .wav)"
done

# Start server via Python wrapper — applies torchaudio patch (soundfile instead
# of torchcodec) before importing TTS, avoiding FFmpeg shared DLL requirement.
# exec replaces bash with the server process so PID management works correctly.
# Port passed via env var to avoid shell injection into Python code.
export XTTS_SERVER_PORT="$PORT"
exec python -c "
import os, sys
import torchaudio_patch  # noqa: F401
port = os.environ.get('XTTS_SERVER_PORT', '8890')
sys.argv = ['tts-server',
    '--model_name', 'tts_models/multilingual/multi-dataset/xtts_v2',
    '--port', port,
    '--device', 'cuda']
from TTS.server.server import main
main()
"
