# claude-stt Plugin Patches

Patched files for the `claude-stt` plugin (v0.1.0) that fix Windows-specific issues.

## What's patched

### keyboard.py — Clipboard paste injection
- Replaces `kb.type(text)` (per-character SendInput) with `pyperclip.copy() + Ctrl+V`
- Fixes text duplication caused by WH_KEYBOARD_LL hook feedback loop on Windows
- Only affects Windows; Linux/macOS paths unchanged

### daemon.py — Singleton mutex guard
- Adds `CreateMutexW("Global\\claude-stt-daemon-singleton")` to prevent multiple daemons
- Fixes TOCTOU race where concurrent SessionStart hooks spawn duplicate daemons
- Each duplicate independently records + transcribes + injects text = Nx duplication

## Re-applying after plugin update

```bash
PLUGIN_PKG="$USERPROFILE/.claude/plugins/cache/jarrodwatts-claude-stt/claude-stt/0.1.0/.venv/Lib/site-packages/claude_stt"
cp src/voice/patches/claude-stt/keyboard.py "$PLUGIN_PKG/keyboard.py"
cp src/voice/patches/claude-stt/daemon.py "$PLUGIN_PKG/daemon.py"
```

Then restart the daemon: `bash src/voice/start-all.sh stop && bash src/voice/start-all.sh`
