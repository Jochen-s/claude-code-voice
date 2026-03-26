"""
Minimal OpenAI-compatible Whisper STT server using faster-whisper.

Serves POST /v1/audio/transcriptions with the same interface as OpenAI's API.
Replaces 'speaches' which lacks Python 3.14 support.

Usage:
  python whisper_server.py --host 127.0.0.1 --port 2022 --model medium
"""

import argparse
import logging
import re
import tempfile
import time
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from faster_whisper import WhisperModel

logger = logging.getLogger("whisper-server")

app = FastAPI(title="faster-whisper STT", version="1.0.0")
model_name: str = "medium"
default_language: str | None = None


def deduplicate_repeated_phrases(text: str) -> str:
    """Remove consecutive duplicate sentences/phrases from Whisper output.

    Whisper large-v3 sometimes hallucinates by repeating segments verbatim.
    This detects and collapses consecutive identical sentences.
    """
    if not text:
        return text
    # Split on sentence boundaries (period, exclamation, question mark)
    sentences = re.split(r'(?<=[.!?])\s*', text)
    sentences = [s.strip() for s in sentences if s.strip()]
    if not sentences:
        return text
    deduped = [sentences[0]]
    for s in sentences[1:]:
        if s.lower() != deduped[-1].lower():
            deduped.append(s)
    result = " ".join(deduped)
    if len(deduped) < len(sentences):
        logger.info("Dedup: removed %d repeated segments", len(sentences) - len(deduped))
    return result


@app.get("/health")
async def health():
    return {"status": "ok", "model": model_name, "backend": "faster-whisper"}


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(default="whisper-1"),
    language: str | None = Form(default=None),
    prompt: str | None = Form(default=None),
    response_format: str = Form(default="json"),
    temperature: float = Form(default=0.0),
):
    """OpenAI-compatible transcription endpoint."""
    whisper = getattr(app.state, 'model', None)
    if whisper is None:
        return JSONResponse(
            {"error": "Model not loaded yet"}, status_code=503
        )

    # Write upload to temp file (faster-whisper needs a file path or numpy array)
    suffix = Path(file.filename).suffix if file.filename else ".wav"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = tmp.name

    try:
        t0 = time.time()
        kwargs = {"beam_size": 5}
        # Client language > server default > auto-detect
        lang = language or default_language
        if lang:
            kwargs["language"] = lang
        if prompt:
            kwargs["initial_prompt"] = prompt
        if temperature > 0:
            kwargs["temperature"] = temperature

        segments, info = whisper.transcribe(tmp_path, **kwargs)
        segments_list = list(segments)
        elapsed = time.time() - t0

        full_text = " ".join(s.text.strip() for s in segments_list)
        full_text = deduplicate_repeated_phrases(full_text)
        logger.info(
            "Transcribed %.1fs audio in %.3fs (%.1fx RT) lang=%s",
            info.duration,
            elapsed,
            info.duration / elapsed if elapsed > 0 else 0,
            info.language,
        )

        if response_format == "text":
            return PlainTextResponse(full_text)
        elif response_format == "verbose_json":
            return JSONResponse(
                {
                    "task": "transcribe",
                    "language": info.language,
                    "duration": info.duration,
                    "text": full_text,
                    "segments": [
                        {
                            "id": i,
                            "start": s.start,
                            "end": s.end,
                            "text": s.text.strip(),
                        }
                        for i, s in enumerate(segments_list)
                    ],
                }
            )
        else:
            # Default: json (matches OpenAI format)
            return JSONResponse({"text": full_text})
    finally:
        Path(tmp_path).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="faster-whisper STT server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2022)
    parser.add_argument("--model", default="medium")
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--compute-type", default="float16")
    parser.add_argument("--language", default=None, help="Default language (e.g. 'en'). Prevents auto-detect guessing wrong locale.")
    args = parser.parse_args()

    global model_name, default_language
    model_name = args.model
    default_language = args.language

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    logger.info(
        "Loading model '%s' on %s (%s)...", args.model, args.device, args.compute_type
    )
    t0 = time.time()
    app.state.model = WhisperModel(
        args.model, device=args.device, compute_type=args.compute_type
    )
    logger.info("Model loaded in %.2fs", time.time() - t0)

    logger.info("Starting server on %s:%d", args.host, args.port)
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
