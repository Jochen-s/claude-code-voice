#!/usr/bin/env bash
# Install Coqui XTTS-v2 for character voice cloning
# Requires ~1.8GB for model download, GPU recommended
set -euo pipefail

# Resolve home to a path that works in both MINGW64 and native Windows
if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
VOICES_DIR="$WIN_HOME/.claude/voices"
PYTHON="$(command -v python.exe 2>/dev/null || command -v python3 2>/dev/null || command -v python 2>/dev/null)"

mkdir -p "$SERVICES_DIR" "$VOICES_DIR"

venv="$SERVICES_DIR/xtts-venv"
if [ ! -d "$venv" ]; then
  "$PYTHON" -m venv "$venv"
  echo "Created XTTS venv at $venv"
fi

source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

python -m pip install --upgrade pip
# PyTorch with CUDA 12.8 (RTX 5090)
python -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128

python -m pip install "coqui-tts[codec,server]" "transformers<5"

# Install torchaudio patch into venv — routes audio loading through soundfile
# instead of torchcodec (which requires FFmpeg shared DLLs that static builds lack)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/torchaudio_patch.py" "$venv/Lib/site-packages/" 2>/dev/null \
  || cp "$SCRIPT_DIR/torchaudio_patch.py" "$venv/lib/python*/site-packages/" 2>/dev/null \
  || echo "Warning: could not install torchaudio_patch.py into venv"

# Pre-download the XTTS-v2 model
echo "Downloading XTTS-v2 model (~1.8GB)..."
python -c "
import torchaudio_patch  # noqa: F401 — patches torchaudio.load before TTS import
from TTS.api import TTS
import torch
device = 'cuda' if torch.cuda.is_available() else 'cpu'
tts = TTS(model_name='tts_models/multilingual/multi-dataset/xtts_v2').to(device)
print(f'XTTS-v2 model downloaded and ready (device: {device})')
" 2>&1 || echo "Model will download on first use"

deactivate 2>/dev/null || true

echo ""
echo "XTTS-v2 installed. Next steps:"
echo ""
echo "1. Reference audio already downloaded:"
echo "   $VOICES_DIR/kitt.wav          (William Daniels)"
echo "   $VOICES_DIR/trek-computer.wav (Majel Barrett)"
echo "   $VOICES_DIR/jarvis-high.onnx  (Piper model - use directly)"
echo ""
echo "2. Test voice cloning:"
echo "   source $venv/Scripts/activate"
echo "   tts --model_name tts_models/multilingual/multi-dataset/xtts_v2 \\"
echo "       --speaker_wav $VOICES_DIR/kitt.wav \\"
echo "       --text 'Captain, sensors detect a new code review approaching.' \\"
echo "       --out_path /tmp/test-kitt.wav"
echo ""
echo "3. Start the server:"
echo "   bash start-xtts-server.sh"
