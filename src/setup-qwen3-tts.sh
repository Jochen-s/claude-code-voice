#!/usr/bin/env bash
# Install Qwen3-TTS OpenAI-compatible server (groxaxo/Qwen3-TTS-Openai-Fastapi)
# Requires: Python 3.12, NVIDIA GPU with CUDA 12.8+
# Result: Qwen3-TTS running on port 8880 with /v1/audio/speech endpoint
set -euo pipefail

if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
REPO_DIR="$SERVICES_DIR/qwen3-tts"
PYTHON="${VOICEMODE_PYTHON:-$(command -v python.exe 2>/dev/null || command -v python3 2>/dev/null || command -v python 2>/dev/null)}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

mkdir -p "$SERVICES_DIR"

# Check Python version (need 3.12)
py_ver=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
info "Python version: $py_ver"
if [[ "$py_ver" != "3.12" && "$py_ver" != "3.11" && "$py_ver" != "3.13" ]]; then
  warn "Python $py_ver detected. 3.12 recommended. Trying py -3.12..."
  if command -v py &>/dev/null && py -3.12 --version &>/dev/null; then
    PYTHON="$(py -3.12 -c 'import sys; print(sys.executable)')"
  else
    error "Python 3.11-3.13 required. Install Python 3.12 and retry."
    exit 1
  fi
fi

# Clone or update repo
if [ -d "$REPO_DIR/.git" ]; then
  info "Updating Qwen3-TTS-Openai-Fastapi..."
  git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "Could not update (detached HEAD?)"
else
  info "Cloning Qwen3-TTS-Openai-Fastapi..."
  git clone https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi.git "$REPO_DIR"
fi

# Create venv
venv="$REPO_DIR/.venv"
if [ ! -d "$venv" ]; then
  info "Creating venv..."
  $PYTHON -m venv "$venv"
fi
source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

# Install PyTorch with CUDA 12.8 (RTX 5090 / Blackwell)
info "Installing PyTorch with CUDA 12.8..."
python -m pip install --upgrade pip
python -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128

# Install Qwen3-TTS server with API extras
info "Installing Qwen3-TTS server..."
cd "$REPO_DIR"
python -m pip install -e ".[api]"

# System deps check
for cmd in ffmpeg sox; do
  if ! command -v $cmd &>/dev/null; then
    warn "$cmd not found. Install via: conda install -c conda-forge $cmd"
  fi
done

# Optional: flash-attn (10% speedup, skip if it fails)
info "Attempting flash-attn install (optional, ~10% speedup)..."
python -m pip install flash-attn --no-build-isolation 2>/dev/null || warn "flash-attn skipped (builds fine on Linux, often fails on Windows). Standard attention will be used."

# Warmup: download model on first import
info "Pre-downloading Qwen3-TTS model (~3-4 GB)..."
TTS_WARMUP_ON_START=true PORT=0 timeout 120 python -c "
from qwen_tts import Qwen3TTS
print('Qwen3-TTS model downloaded')
" 2>&1 || warn "Model will download on first server start"

deactivate 2>/dev/null || true
info "Qwen3-TTS installed at $REPO_DIR"
info "Start with: bash start-qwen3-tts-server.sh (port 8880)"
