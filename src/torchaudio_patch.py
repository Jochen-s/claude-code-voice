"""Patch torchaudio.load/save to use soundfile instead of torchcodec.

torchcodec requires FFmpeg shared DLLs (.dll) which static FFmpeg builds
(like gyan.dev full_build) don't ship. This patch routes audio I/O
through soundfile instead, which handles WAV/FLAC/OGG natively.

Import this module before importing TTS/coqui-tts:
    import torchaudio_patch  # noqa: F401
    from TTS.api import TTS
"""
from pathlib import Path

import soundfile as sf
import torch
import torchaudio


def _load_via_soundfile(source, *args, **kwargs):
    """Load audio using soundfile, returning torchaudio-compatible output.

    Handles file paths (str/Path) and file-like objects (BytesIO).
    Returns: (waveform: Tensor[channels, time], sample_rate: int)
    """
    if isinstance(source, bytes):
        # bytes = raw path encoded as bytes — decode to str
        source = source.decode('utf-8')
    if isinstance(source, (str, Path)):
        audio, sr = sf.read(source, dtype='float32')
    else:
        # File-like object (BytesIO) — rewind if needed
        if hasattr(source, 'seek'):
            source.seek(0)
        audio, sr = sf.read(source, dtype='float32')
    audio = torch.FloatTensor(audio)
    if audio.dim() == 1:
        audio = audio.unsqueeze(0)  # [time] -> [1, time]
    elif audio.dim() == 2:
        audio = audio.T  # soundfile [time, ch] -> torchaudio [ch, time]
    return audio, sr


def _save_via_soundfile(dest, src, sample_rate, **kwargs):
    """Save audio using soundfile. Handles file paths and file-like objects."""
    fmt = kwargs.get('format', 'WAV').upper()
    sf_format = {'WAV': 'WAV', 'FLAC': 'FLAC', 'OGG': 'OGG'}.get(fmt, 'WAV')
    data = src.cpu()
    if data.dim() == 2:
        data = data.T  # torchaudio [ch, time] -> soundfile [time, ch]
    elif data.dim() == 1:
        data = data.unsqueeze(1)  # [time] -> [time, 1]
    sf.write(dest, data.numpy(), sample_rate, format=sf_format)


# Only patch if torchaudio uses torchcodec backend (>= 2.5)
# Older versions use sox/soundfile natively and don't need this.
_needs_patch = not hasattr(torchaudio, '_backend_utils') or \
    getattr(torchaudio, '__version__', '0') >= '2.5'

if _needs_patch:
    torchaudio.load = _load_via_soundfile
    torchaudio.save = _save_via_soundfile
