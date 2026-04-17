#!/usr/bin/env bash
# Voice Services Setup for Claude Code
# Installs Kokoro TTS and faster-whisper STT as local services
# Designed for Windows (MINGW64/Git Bash) with RTX 5090 GPU
#
# Usage: bash setup-voice-services.sh [--kokoro] [--whisper] [--all]

set -euo pipefail

# Resolve home to a path that works in both MINGW64 and native Windows
if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
VOICEMODE_DIR="$WIN_HOME/.voicemode"
SERVICES_DIR="$VOICEMODE_DIR/services"
MODELS_DIR="$VOICEMODE_DIR/models"
VOICES_DIR="$WIN_HOME/.claude/voices"
# Resolve python binary (python.exe on Windows, python3 on Linux)
PYTHON="$(command -v python.exe 2>/dev/null || command -v python3 2>/dev/null || command -v python 2>/dev/null)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

ensure_dirs() {
  mkdir -p "$SERVICES_DIR" "$MODELS_DIR/kokoro" "$MODELS_DIR/whisper" "$VOICES_DIR"
  info "Directories created"
}

install_kokoro() {
  info "Installing Kokoro TTS (OpenAI-compatible server)..."

  # Create a dedicated venv for Kokoro
  local venv="$SERVICES_DIR/kokoro-venv"
  if [ ! -d "$venv" ]; then
    "$PYTHON" -m venv "$venv"
    info "Created Kokoro venv at $venv"
  fi

  # Activate and install
  source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

  python -m pip install --upgrade pip
  python -m pip install kokoro-onnx onnxruntime soundfile numpy

  # Download the Kokoro ONNX model if not present
  local model_dir="$MODELS_DIR/kokoro"
  if [ ! -f "$model_dir/kokoro-v1.0.onnx" ]; then
    info "Downloading Kokoro ONNX model (~350MB)..."
    python -m pip install huggingface-hub
    MODEL_DIR="$model_dir" python -c "
from huggingface_hub import hf_hub_download
import shutil, os
dest = os.environ['MODEL_DIR']
# Model files moved to fastrtc/kokoro-onnx (hexgrad/Kokoro-82M no longer hosts ONNX)
model_path = hf_hub_download('fastrtc/kokoro-onnx', 'kokoro-v1.0.onnx')
voices_path = hf_hub_download('fastrtc/kokoro-onnx', 'voices-v1.0.bin')
shutil.copy(model_path, os.path.join(dest, 'kokoro-v1.0.onnx'))
shutil.copy(voices_path, os.path.join(dest, 'voices-v1.0.bin'))
print(f'Model downloaded to {dest}')
"
  else
    info "Kokoro model already present"
  fi

  deactivate 2>/dev/null || true
  info "Kokoro TTS installed"
}

install_kokoro_server() {
  info "Installing Kokoro server dependencies (FastAPI + uvicorn)..."

  # Reuse the kokoro-venv (no separate server venv needed)
  local venv="$SERVICES_DIR/kokoro-venv"
  source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

  python -m pip install fastapi uvicorn

  deactivate 2>/dev/null || true
  info "Kokoro server dependencies installed"
  info "Start with: voice start  (or: bash src/start-kokoro-server.sh from repo root)"
}

install_whisper() {
  info "Installing faster-whisper STT..."

  local venv="$SERVICES_DIR/whisper-venv"
  if [ ! -d "$venv" ]; then
    "$PYTHON" -m venv "$venv"
    info "Created Whisper venv at $venv"
  fi

  source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

  python -m pip install --upgrade pip
  # faster-whisper with CUDA support
  python -m pip install faster-whisper

  # Install NVIDIA cuBLAS runtime (needed by CTranslate2 for CUDA)
  info "Installing NVIDIA cuBLAS for CUDA support..."
  python -m pip install nvidia-cublas-cu12 || warn "cuBLAS install failed -- GPU mode may not work"

  # Copy cuBLAS DLLs next to ctranslate2.dll (Windows DLL search path fix)
  local ct2_dir
  ct2_dir="$(python -c "import ctranslate2, os; print(os.path.dirname(ctranslate2.__file__))")"
  local cublas_dir
  cublas_dir="$(python -c "
import importlib.util, os
spec = importlib.util.find_spec('nvidia.cublas')
if spec and spec.submodule_search_locations:
    d = list(spec.submodule_search_locations)[0]
    b = os.path.join(d, 'bin')
    if os.path.isdir(b): print(b)
" 2>/dev/null)"
  if [ -n "$cublas_dir" ] && [ -d "$cublas_dir" ]; then
    for dll in "$cublas_dir"/cublas64_*.dll "$cublas_dir"/cublasLt64_*.dll; do
      [ -f "$dll" ] && cp "$dll" "$ct2_dir/" && info "Copied $(basename "$dll") to CT2 dir"
    done
  else
    warn "cuBLAS DLLs not found -- GPU inference may fail with 'cublas64_12.dll not found'"
  fi

  # Download the large-v3 model (default for RTX 5090)
  local dl_model="${VOICEMODE_WHISPER_MODEL:-large-v3}"
  info "Pre-downloading Whisper $dl_model model..."
  python -c "
from faster_whisper import WhisperModel
model = WhisperModel('$dl_model', device='auto', compute_type='auto')
print('Whisper $dl_model model downloaded and ready')
" 2>&1 || warn "Model download may need CUDA. Will download on first use."

  deactivate 2>/dev/null || true
  info "faster-whisper installed"
}

install_whisper_server() {
  info "Installing Whisper server (OpenAI-compatible)..."

  local venv="$SERVICES_DIR/whisper-venv"
  source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

  # FastAPI-based server (whisper_server.py) -- works on Python 3.14
  python -m pip install fastapi uvicorn python-multipart

  deactivate 2>/dev/null || true
  info "Whisper server installed (using whisper_server.py)"
  info "Start with: voice start  (or: bash src/start-whisper-server.sh from repo root)"
}

install_qwen3_tts() {
  info "Delegating to src/setup-qwen3-tts.sh..."
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$script_dir/src/setup-qwen3-tts.sh"
}

install_chatterbox() {
  info "Delegating to src/setup-chatterbox.sh..."
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$script_dir/src/setup-chatterbox.sh"
}

show_usage() {
  echo "Usage: $0 [--kokoro] [--whisper] [--qwen3] [--chatterbox] [--all]"
  echo ""
  echo "  --kokoro      Install Kokoro TTS (lightweight, ONNX)"
  echo "  --whisper     Install faster-whisper STT (large-v3)"
  echo "  --qwen3       Install Qwen3-TTS (best quality, voice cloning)"
  echo "  --chatterbox  Install Chatterbox (MIT, emotion control, cloning)"
  echo "  --all         Install recommended stack (qwen3 + chatterbox + whisper)"
  echo ""
  echo "After installation, start services with:"
  echo "  voice start    (starts all configured services)"
  echo ""
  echo "Recommended stack (RTX 5090):"
  echo "  Port 8880: Qwen3-TTS    (default TTS, ~4 GB VRAM)"
  echo "  Port 8890: Chatterbox   (voice cloning, ~7 GB VRAM)"
  echo "  Port 2022: faster-whisper large-v3 (STT, ~6 GB VRAM)"
}

main() {
  if [ $# -eq 0 ]; then
    show_usage
    exit 0
  fi

  ensure_dirs

  for arg in "$@"; do
    case "$arg" in
      --kokoro)
        install_kokoro
        install_kokoro_server
        ;;
      --whisper)
        install_whisper
        install_whisper_server
        ;;
      --qwen3)
        install_qwen3_tts
        ;;
      --chatterbox)
        install_chatterbox
        ;;
      --all)
        install_qwen3_tts
        install_chatterbox
        install_whisper
        install_whisper_server
        ;;
      *)
        error "Unknown option: $arg"
        show_usage
        exit 1
        ;;
    esac
  done

  info "Setup complete. Start services and restart Claude Code to use voice."
}

main "$@"
