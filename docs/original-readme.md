# Claude Code Voice Integration

Bidirectional voice for Claude Code CLI: speak to Claude (STT) and hear responses (TTS) with switchable character voices.

## Architecture

```
                    +-------------------+
  Microphone  --->  | claude-stt plugin |  ---> Claude Code stdin
                    | (push-to-talk)    |       (keyboard injection)
                    +-------------------+
                            |
                  +---------v----------+
                  | faster-whisper GPU  |
                  | Port 2022 (large-v3)|
                  +--------------------+

                    +------------------+
  Speakers    <---  | tts-marker-hook  |  <--- Claude Code stdout
                    | (<<tts>> tags)   |
                    +------------------+
                         |
              +----------+----------+
              |                     |
    +---------v---------+   +-------v-----------+
    | Qwen3-TTS         |   | Chatterbox        |
    | Port 8880          |   | Port 8890         |
    | (default voice)    |   | (voice cloning)   |
    +-------------------+   +-------------------+
```

## Quick Start

### 1. Install (one-time)

```bash
# Recommended stack: Qwen3-TTS + Chatterbox + faster-whisper
bash src/voice/setup-voice-services.sh --all

# Or install individually:
bash src/voice/setup-qwen3-tts.sh       # Port 8880 -- default TTS
bash src/voice/setup-chatterbox.sh       # Port 8890 -- voice cloning
bash src/voice/setup-voice-services.sh --whisper  # Port 2022 -- STT
```

### 2. Start/Stop Services

```bash
voice start    # Start all services (alias from ~/.bashrc)
voice stop     # Stop all services
voice status   # Check service health
```

Or manually:
```bash
bash src/voice/start-all.sh start
bash src/voice/start-all.sh stop
bash src/voice/start-all.sh status
```

### 3. Push-to-Talk (STT Input)

**Hotkey**: Hold `Ctrl+F12` to record, release to transcribe.

The `claude-stt` plugin auto-starts with each Claude Code session. It sends audio to the faster-whisper server at port 2022 (GPU-accelerated, large-v3 model).

### 4. Switch Voice

```bash
bash src/voice/switch-voice.sh jarvis    # Qwen3-TTS am_onyx voice
bash src/voice/switch-voice.sh picard    # Chatterbox voice clone
bash src/voice/switch-voice.sh default   # Qwen3-TTS af_sky voice
```

## Voice Profiles

| Profile | Engine | Voice ID | Description |
|---------|--------|----------|-------------|
| default | Qwen3-TTS | af_sky | Natural female, fast |
| jarvis | Qwen3-TTS | am_onyx | J.A.R.V.I.S. - deep male voice |
| seven | Qwen3-TTS | af_kore | Seven of Nine - precise female voice |
| kitt-clone | Chatterbox | kitt-daniels.wav | KITT (William Daniels clone) |
| trek-computer | Chatterbox | trek-computer.wav | Star Trek Computer (Majel Barrett clone) |
| picard | Chatterbox | picard-stewart.wav | Captain Picard (Patrick Stewart clone) |
| scotty | Chatterbox | scotty-p263.wav | Scotty (Scottish accent clone) |
| kokoro-default | Kokoro | af_sky | Legacy lightweight fallback |
| kokoro-jarvis | Kokoro | bm_george | Legacy J.A.R.V.I.S. fallback |

## Service Stack

| Service | Port | Engine | VRAM | Purpose |
|---------|------|--------|------|---------|
| Qwen3-TTS | 8880 | Qwen3-TTS-12Hz-1.7B | ~4-8 GB | Default TTS, built-in voices |
| Chatterbox | 8890 | Chatterbox-Turbo | ~4-7 GB | Voice cloning, emotion control |
| faster-whisper | 2022 | Whisper large-v3 | ~6 GB | Speech-to-text |
| **Total** | | | **~14-21 GB** | **of 32 GB RTX 5090** |

All three serve OpenAI-compatible APIs (`/v1/audio/speech` and `/v1/audio/transcriptions`).

### Legacy Fallbacks

If the new engines are not installed, `voice start` falls back to:
- Kokoro TTS on port 8880 (lightweight ONNX, <200ms)
- XTTS-v2 on port 8890 (Coqui voice cloning)

## Configuration

### STT Config: `~/.claude/plugins/claude-stt/config.toml`

| Setting | Value | Description |
|---------|-------|-------------|
| engine | server | Uses remote faster-whisper via HTTP |
| server_url | http://127.0.0.1:2022/v1/audio/transcriptions | GPU-accelerated STT |
| hotkey | ctrl+f12 | Push-to-talk trigger |
| mode | push-to-talk | Hold to record, release to transcribe |

### Environment Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| VOICEMODE_QWEN3_PORT | 8880 | Qwen3-TTS port |
| VOICEMODE_CHATTERBOX_PORT | 8890 | Chatterbox port |
| VOICEMODE_WHISPER_PORT | 2022 | Whisper STT port |
| VOICEMODE_WHISPER_MODEL | large-v3 | Whisper model (large-v3, medium, etc.) |

### Chatterbox Emotion Control

Voice-cloned profiles support emotion parameters via the `/tts` endpoint:

| Parameter | Default | Range | Effect |
|-----------|---------|-------|--------|
| exaggeration | 0.5 | 0.0-2.0 | Emotional intensity |
| cfg_weight | 0.5 | 0.0-1.0 | Guidance strength |
| temperature | 0.8 | 0.05-5.0 | Randomness |

## Stream Deck Plus Integration

Toggle voice services on/off from an Elgato Stream Deck button.

### Setup (Multi Action Switch -- recommended)

1. Open Stream Deck software
2. Drag **"Multi Action Switch"** (System) onto a button
3. **State 1** (button shows "Voice ON"): add "System > Open" action
   - App/File: `C:\LocalAgent\src\voice\voice-stop.vbs`
4. **State 2** (button shows "Voice OFF"): add "System > Open" action
   - App/File: `C:\LocalAgent\src\voice\voice-start.vbs`

Note: Labels show the *current state*, actions do the *opposite*. State 1 shows "Voice ON" and the action stops it; State 2 shows "Voice OFF" and the action starts it.

### Setup (Single toggle button)

1. Drag **"System > Open"** onto a button
2. App/File: `C:\LocalAgent\src\voice\voice-toggle.vbs`

The toggle auto-detects whether services are running via port check.

Important: Use the `.vbs` files, not `.bat`. Stream Deck opens `.bat` files in Notepad instead of executing them.

## File Structure

```
src/voice/
  README.md                  # This file
  setup-voice-services.sh    # Install all services (--qwen3 --chatterbox --whisper --all)
  setup-qwen3-tts.sh         # Install Qwen3-TTS server
  setup-chatterbox.sh        # Install Chatterbox server
  start-all.sh               # Start/stop/status all services
  start-qwen3-tts-server.sh  # Start Qwen3-TTS (port 8880)
  start-chatterbox-server.sh # Start Chatterbox (port 8890)
  start-whisper-server.sh    # Start Whisper STT (port 2022)
  whisper_server.py          # FastAPI whisper server
  switch-voice.sh            # Switch active voice profile
  voice-profiles.json        # Voice profile configuration
  tts-marker-hook.js         # Stop hook for TTS marker extraction
  voice-start.bat/.vbs       # Start services (Stream Deck)
  voice-stop.bat/.vbs        # Stop services (Stream Deck)
  voice-toggle.bat/.vbs      # Toggle services (Stream Deck)

~/.claude/voices/            # Reference audio for voice cloning
~/.voicemode/services/       # Service installations
  qwen3-tts/                 # Qwen3-TTS-Openai-Fastapi repo + venv
  chatterbox/                # Chatterbox-TTS-Server repo + venv
  kokoro-venv/               # Kokoro ONNX (legacy)
  whisper-venv/              # faster-whisper
```

## Verification

```bash
# Check all services
voice status

# Test STT
curl http://127.0.0.1:2022/health

# Test Qwen3-TTS (am_onyx = deep male Jarvis voice)
curl -X POST http://127.0.0.1:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-tts","input":"Hello world","voice":"am_onyx"}' \
  --output /tmp/test.wav

# Test Chatterbox (voice-cloned Picard)
curl -X POST http://127.0.0.1:8890/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"chatterbox-turbo","input":"Hello world","voice":"picard-stewart.wav"}' \
  --output /tmp/test-cb.wav

# Full loop: speak -> transcribe -> Claude -> TTS -> audio
```
