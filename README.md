# Claude Code Voice

> "Computer, begin recording." -- Captain Picard

Voice mode for [Claude Code](https://docs.anthropic.com/en/docs/claude-code): text-to-speech output and speech-to-text input with swappable engines, voice profiles, and a guillemet-marker hook pipeline.

Talk to your AI agent. Have it talk back.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-Compatible-green.svg)](https://docs.anthropic.com/en/docs/claude-code)

---

## How It Works

1. Claude wraps spoken prose in guillemet markers: `<<tts>>Hello, Number One.<</ tts>>`
2. A Stop hook (`tts-marker-hook.js`) fires after each assistant turn
3. The hook extracts marked text and sends it to the active TTS engine
4. Audio plays through your speakers

For input: a push-to-talk daemon captures your microphone, sends audio to a local Whisper server, and injects the transcription into Claude Code's input.

No cloud services. No API keys for voice. Everything runs locally on your GPU.

---

## Architecture

```
You speak ──> [Push-to-Talk] ──> [faster-whisper :2022] ──> Claude Code input
                                                                    │
                                                              Claude thinks
                                                                    │
Claude output ──> [<<tts>> markers] ──> [tts-marker-hook.js] ──> [TTS Engine] ──> speakers
```

### TTS Engines

| Engine | Port | VRAM | Strength | Voice Cloning |
|--------|------|------|----------|---------------|
| **Qwen3-TTS** | 8880 | ~4-8GB | Natural prosody, multilingual | No (built-in voices) |
| **Chatterbox** | 8890 | ~4-7GB | Voice cloning from 3s sample | Yes (reference audio) |
| **Kokoro** | 8870 | ~2GB | Lightweight, fast | No |
| **XTTS v2** | 8860 | ~4GB | Legacy, multilingual | Yes |

All engines expose `/v1/audio/speech` (OpenAI-compatible API). Swapping engines is a profile change, not a code change.

### STT Engine

| Engine | Port | VRAM | Model |
|--------|------|------|-------|
| **faster-whisper** | 2022 | ~6GB | large-v3 (configurable) |

---

## Voice Profiles

Profiles define which TTS engine, voice, and parameters to use. Stored in `profiles/voice-profiles.json`.

```json
{
  "picard": {
    "engine": "chatterbox",
    "port": 8890,
    "voice": "picard-stewart.wav",
    "params": { "exaggeration": 0.6, "cfg_weight": 0.5, "temperature": 0.8 }
  },
  "default": {
    "engine": "qwen3-tts",
    "port": 8880,
    "voice": "Chelsie",
    "params": {}
  }
}
```

Switch profiles at runtime:
```bash
./src/switch-voice.sh picard    # Use Chatterbox with Picard voice clone
./src/switch-voice.sh default   # Use Qwen3-TTS default voice
```

---

## Requirements

- **GPU**: NVIDIA with CUDA support (6GB+ VRAM minimum, 16GB+ recommended for multiple engines)
- **Python**: 3.10+ with pip/uv
- **Node.js**: 18+ (for hooks)
- **OS**: Windows (MINGW64/Git Bash), Linux, or WSL
- **Claude Code**: Installed and configured
- **Optional**: [claude-stt plugin](https://github.com/jarrodwatts/claude-stt) for push-to-talk

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/Jochen-s/claude-code-voice.git
cd claude-code-voice
```

### 2. Set up TTS engine(s)

```bash
# Option A: Qwen3-TTS (recommended for getting started)
bash src/setup-qwen3-tts.sh

# Option B: Chatterbox (for voice cloning)
bash src/setup-chatterbox.sh

# Option C: All engines
bash setup-voice-services.sh
```

### 3. Set up STT

```bash
bash src/start-whisper-server.sh
```

### 4. Install the TTS hook

```bash
cp hooks/tts-marker-hook.js ~/.claude/hooks/
```

Then register in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node ~/.claude/hooks/tts-marker-hook.js",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### 5. Add the voice output rule

Create `~/.claude/rules/voice-output.md`:

```markdown
Wrap natural language prose in <<tts>>...<</ tts>> markers for text-to-speech.
Do NOT wrap: code, commands, errors, technical lists.
Keep markers on same line as text.
```

### 6. Start everything

```bash
# Linux/WSL
bash start-all.sh

# Windows
voice-start.bat
# or double-click voice-start.vbs for silent background launch
```

### 7. Talk to Claude

Open Claude Code. It will speak its responses and you can use push-to-talk for input.

---

## File Structure

```
claude-code-voice/
  hooks/
    tts-marker-hook.js    # Stop hook: extracts <<tts>> markers, sends to TTS
    stt-dedup-guard.js    # PreToolUse hook: deduplicates STT transcriptions
  src/
    kokoro_server.py      # Kokoro TTS server (lightweight)
    whisper_server.py     # faster-whisper STT server
    torchaudio_patch.py   # Compatibility patch for torchaudio
    switch-voice.sh       # Runtime profile switcher
    setup-*.sh            # Engine setup scripts
    start-*.sh            # Engine start scripts
  profiles/
    voice-profiles.json   # Engine/voice/parameter definitions
  patches/                # Compatibility patches for specific engines
  docs/                   # Additional documentation
  setup-voice-services.sh # One-shot setup for all engines
  start-all.sh            # Start all configured services
  voice-start.bat         # Windows launcher
  voice-stop.bat          # Windows stop script
  voice-toggle.bat        # Windows toggle
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No audio output | TTS server not running | Check `curl http://localhost:8880/v1/models` |
| Wrong voice | Profile not switched | Run `./src/switch-voice.sh <profile>` |
| CUDA out of memory | Too many engines running | Run one TTS engine at a time |
| STT not transcribing | Whisper server down | Check `curl http://localhost:2022/health` |
| Duplicate transcriptions | STT fires twice | Install `stt-dedup-guard.js` hook |
| MINGW64 path issues | `$HOME` vs `$USERPROFILE` | Use `cygpath -u "$USERPROFILE"` |
| `chatterbox not installed` / `whisper not installed` on `voice start` | Helper scripts in `src/` not found | Verify `ls src/start-*-server.sh` resolves; confirm `start-all.sh` references `$HELPERS_DIR`, not `$SCRIPT_DIR` directly |
| `./src/switch-voice.sh` fails with "No such file" for `voice-profiles.json` | Profiles live at `profiles/voice-profiles.json`, not `src/` | Run from repo root; override with `VOICE_PROFILES_PATH=...` if you moved the file |
| Chatterbox voice sounds wrong | Bad reference audio | Use a clean 3-10s WAV clip, single speaker, no background noise |

---

## Companion Project

This is the voice module for [Starfleet Claude Code](https://github.com/Jochen-s/starfleet-claude-code), a Star Trek-themed toolkit for Claude Code with multi-faction review, behavioral learning, and self-aware context management.

Voice mode is fully optional. Starfleet Claude Code works without it.

---

## License

MIT License. Copyright (c) 2026 Jochen Schmiedbauer.

See [LICENSE](LICENSE) for full text.
