"""
Kokoro TTS - OpenAI-compatible /v1/audio/speech server.

Wraps kokoro-onnx with a FastAPI endpoint matching the OpenAI TTS API.
Serves on port 8880 by default.
"""

import io
import os
import sys
import time

import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

# Resolve model paths
_home = os.environ.get("USERPROFILE", os.environ.get("HOME", ""))
_model_dir = os.path.join(_home, ".voicemode", "models", "kokoro")
MODEL_PATH = os.environ.get(
    "KOKORO_MODEL_PATH", os.path.join(_model_dir, "kokoro-v1.0.onnx")
)
VOICES_PATH = os.environ.get(
    "KOKORO_VOICES_PATH", os.path.join(_model_dir, "voices-v1.0.bin")
)

# Lazy-load the model at startup
_kokoro = None


def get_kokoro():
    global _kokoro
    if _kokoro is None:
        from kokoro_onnx import Kokoro

        print(f"Loading Kokoro model from {MODEL_PATH}...")
        t0 = time.time()
        _kokoro = Kokoro(MODEL_PATH, VOICES_PATH)
        print(f"Kokoro loaded in {time.time() - t0:.1f}s")
        print(f"Available voices: {list(_kokoro.get_voices())}")
    return _kokoro


app = FastAPI(title="Kokoro TTS", version="1.0.0")


MAX_INPUT_LENGTH = 4000  # Guard against extremely long TTS requests


class SpeechRequest(BaseModel):
    model: str = "tts-1"
    input: str
    voice: str = "af_sky"
    response_format: str = "wav"
    speed: float = 1.0


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {"id": "tts-1", "object": "model", "owned_by": "kokoro"},
            {"id": "tts-1-hd", "object": "model", "owned_by": "kokoro"},
        ],
    }


@app.get("/v1/voices")
async def list_voices():
    k = get_kokoro()
    voices = list(k.get_voices())
    return {
        "voices": voices,
        "count": len(voices),
    }


@app.post("/v1/audio/speech")
async def create_speech(req: SpeechRequest):
    k = get_kokoro()

    if len(req.input) > MAX_INPUT_LENGTH:
        raise HTTPException(
            status_code=400,
            detail=f"Input too long ({len(req.input)} chars, max {MAX_INPUT_LENGTH})",
        )

    if req.response_format.lower() == "mp3":
        raise HTTPException(
            status_code=400,
            detail="mp3 format not supported; use wav or pcm",
        )

    voices = list(k.get_voices())
    if req.voice not in voices:
        raise HTTPException(
            status_code=400,
            detail=f"Voice '{req.voice}' not found. Available: {voices}",
        )

    if not req.input.strip():
        raise HTTPException(status_code=400, detail="Input text is empty")

    speed = max(0.5, min(2.0, req.speed))

    t0 = time.time()
    audio, sample_rate = k.create(req.input, voice=req.voice, speed=speed)
    gen_time = time.time() - t0
    duration = len(audio) / sample_rate
    print(
        f"Generated {duration:.1f}s audio in {gen_time:.2f}s "
        f"(voice={req.voice}, {len(req.input)} chars)"
    )

    # Encode to requested format
    buf = io.BytesIO()
    fmt = req.response_format.lower()
    if fmt == "wav":
        sf.write(buf, audio, sample_rate, format="WAV", subtype="PCM_16")
        media_type = "audio/wav"
    elif fmt in ("pcm", "raw"):
        # Raw 16-bit PCM, little-endian
        pcm = (audio * 32767).astype(np.int16)
        buf.write(pcm.tobytes())
        media_type = "audio/pcm"
    else:
        sf.write(buf, audio, sample_rate, format="WAV", subtype="PCM_16")
        media_type = "audio/wav"

    buf.seek(0)
    return Response(content=buf.read(), media_type=media_type)


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": _kokoro is not None}


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("KOKORO_PORT", "8880"))
    # Pre-load model
    get_kokoro()
    print(f"Starting Kokoro TTS server on http://127.0.0.1:{port}")
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info")
