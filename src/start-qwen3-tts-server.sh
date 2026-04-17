#!/usr/bin/env bash
# Start Qwen3-TTS as OpenAI-compatible server on port 8880
# Serves: POST /v1/audio/speech (drop-in replacement for Kokoro)
set -euo pipefail

if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
REPO_DIR="$SERVICES_DIR/qwen3-tts"
PORT="${VOICEMODE_QWEN3_PORT:-8880}"

venv="$REPO_DIR/.venv"
if [ ! -d "$venv" ]; then
  echo "Qwen3-TTS not installed. Run: bash src/setup-qwen3-tts.sh (from repo root)"
  exit 1
fi

source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"
cd "$REPO_DIR"

echo "Starting Qwen3-TTS server on port $PORT..."
echo "Endpoint: http://127.0.0.1:$PORT/v1/audio/speech"
echo "Voices:   http://127.0.0.1:$PORT/v1/voices"
echo "Health:   http://127.0.0.1:$PORT/health"
echo "Docs:     http://127.0.0.1:$PORT/docs"

export PORT HOST="${VOICEMODE_QWEN3_HOST:-127.0.0.1}"
export WORKERS=1
export TTS_WARMUP_ON_START=true
export TTS_MAX_CONCURRENT=1

# Performance: CUDA graph capture eliminates ~500 kernel launches per decode step.
# Expected speedup: 3-5x RTF, TTFA from ~1000ms to ~200ms on consumer GPUs.
# See: https://github.com/andimarafioti/faster-qwen3-tts
export TORCH_CUDA_GRAPH="${VOICEMODE_CUDA_GRAPH:-1}"

# Model variant: use 0.6B for lower VRAM and faster inference, 1.7B for higher quality.
# 0.6B: ~2.5 GB VRAM, RTF 3.5-5x with CUDA graphs
# 1.7B: ~4.5 GB VRAM, RTF 2.5-3.5x with CUDA graphs (default, preserves quality)
export TTS_MODEL="${VOICEMODE_QWEN3_MODEL:-Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice}"

exec python -m api.main
