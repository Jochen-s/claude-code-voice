#!/usr/bin/env bash
# Install Chatterbox TTS Server (devnen/Chatterbox-TTS-Server)
# Requires: Python 3.10+, NVIDIA GPU with CUDA 12.8+
# Result: Chatterbox running on port 8890 with /v1/audio/speech endpoint
set -euo pipefail

if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
SERVICES_DIR="$WIN_HOME/.voicemode/services"
REPO_DIR="$SERVICES_DIR/chatterbox"
PYTHON="${VOICEMODE_PYTHON:-$(command -v python.exe 2>/dev/null || command -v python3 2>/dev/null || command -v python 2>/dev/null)}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

mkdir -p "$SERVICES_DIR"

# Check Python version (need 3.10-3.13, prefer 3.12)
py_ver=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
info "Python version: $py_ver"
py_minor=$(echo "$py_ver" | cut -d. -f2)
if [ "$py_minor" -lt 10 ] 2>/dev/null || [ "$py_minor" -gt 13 ] 2>/dev/null; then
  warn "Python $py_ver detected. 3.10-3.13 required. Trying py -3.12..."
  if command -v py &>/dev/null && py -3.12 --version &>/dev/null; then
    PYTHON="$(py -3.12 -c 'import sys; print(sys.executable)')"
  else
    error "Python 3.10-3.13 required. Install Python 3.12 and retry."
    exit 1
  fi
fi

# Clone or update repo
if [ -d "$REPO_DIR/.git" ]; then
  info "Updating Chatterbox-TTS-Server..."
  git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "Could not update"
else
  info "Cloning Chatterbox-TTS-Server..."
  git clone https://github.com/devnen/Chatterbox-TTS-Server.git "$REPO_DIR"
fi

# Create venv
venv="$REPO_DIR/.venv"
if [ ! -d "$venv" ]; then
  info "Creating venv..."
  "$PYTHON" -m venv "$venv"
fi
source "$venv/Scripts/activate" 2>/dev/null || source "$venv/bin/activate"

# Install PyTorch with CUDA 12.8 FIRST (before chatterbox pins it to 2.6)
info "Installing PyTorch with CUDA 12.8..."
python -m pip install --upgrade pip
python -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128

# Install numpy separately (1.26+ needed for Python 3.12, works fine with chatterbox)
info "Installing numpy (1.26+ for Python 3.12 compatibility)..."
python -m pip install "numpy>=1.26,<2.0"

# Install server dependencies (skip numpy pin + chatterbox-tts, handled separately)
info "Installing Chatterbox server dependencies..."
cd "$REPO_DIR"
# Create temp requirements without strict numpy pin and without chatterbox-tts (installed --no-deps below)
if [ -f "requirements-nvidia-cu128.txt" ]; then
  grep -v -E "^numpy|^chatterbox-tts|^#.*torch" requirements-nvidia-cu128.txt > /tmp/cb-requirements.txt
  python -m pip install -r /tmp/cb-requirements.txt
  rm -f /tmp/cb-requirements.txt
else
  grep -v -E "^numpy|^chatterbox-tts|^torch" requirements.txt > /tmp/cb-requirements.txt
  python -m pip install -r /tmp/cb-requirements.txt
  rm -f /tmp/cb-requirements.txt
fi

# Install chatterbox without its torch dependency (prevents downgrade)
info "Installing Chatterbox TTS (no-deps to preserve CUDA 12.8 torch)..."
python -m pip install --no-deps git+https://github.com/resemble-ai/chatterbox.git@master

# Configure for port 8890
if [ -f "config.yaml" ]; then
  info "Updating config.yaml for port 8890..."
  sed -i 's/port: [0-9]*/port: 8890/' config.yaml 2>/dev/null || true
else
  warn "config.yaml not found -- server will use default port. Edit config.yaml to set port: 8890"
fi

# Copy reference voices if they exist
VOICES_DIR="$WIN_HOME/.claude/voices"
if [ -d "$VOICES_DIR" ] && [ -d "$REPO_DIR/voices" ]; then
  info "Linking reference voices..."
  for wav in "$VOICES_DIR"/*.wav; do
    [ -f "$wav" ] && cp -n "$wav" "$REPO_DIR/voices/" 2>/dev/null && info "  Copied $(basename "$wav")"
  done
fi

deactivate 2>/dev/null || true
info "Chatterbox installed at $REPO_DIR"
info "Start with: bash start-chatterbox-server.sh (port 8890)"
