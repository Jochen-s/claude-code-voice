#!/usr/bin/env bash
# Start all voice services in background
# Usage: bash start-all.sh             (start — Chatterbox + Whisper only)
#        VOICEMODE_ENABLE_TTS=1 bash start-all.sh  (start — all incl. Qwen3-TTS)
#        bash start-all.sh stop        (stop all)
#        bash start-all.sh status      (check health)
#
# Qwen3-TTS (port 8880) is disabled by default — only needed for preset voices
# (jarvis, seven, default). Picard and other cloned voices use Chatterbox directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS_DIR="$SCRIPT_DIR/src"
# Resolve home to a path that works in both MINGW64 and native Windows
if command -v cygpath &>/dev/null; then
  WIN_HOME="$(cygpath -u "$USERPROFILE")"
else
  WIN_HOME="${USERPROFILE:-$HOME}"
fi
VM_DIR="$WIN_HOME/.voicemode"
PID_DIR="$VM_DIR/pids"
LOG_DIR="$VM_DIR/logs"
mkdir -p "$PID_DIR" "$LOG_DIR"

wait_for_port() {
  local port="$1" tries=0
  while [ $tries -lt 30 ]; do
    # Try /health first, then root / (Chatterbox has no /health endpoint)
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1 \
    || curl -sf "http://127.0.0.1:$port/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    tries=$((tries + 1))
  done
  return 1
}

# Generic service starter: start_svc <name> <script> <port>
start_svc() {
  local name="$1" script="$2" port="$3"
  if [ -f "$PID_DIR/$name.pid" ] && kill -0 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null; then
    echo "  $name already running (PID $(cat "$PID_DIR/$name.pid"), port $port)"
  elif [ -f "$script" ]; then
    bash "$script" > "$LOG_DIR/$name.log" 2>&1 &
    echo $! > "$PID_DIR/$name.pid"
    echo "  $name starting (PID $!, port $port)..."
  else
    echo "  $name not installed (missing $script)"
  fi
}

start_services() {
  echo "Starting voice services..."
  # DEPENDENCY CHECKLIST — this function MUST start all 4 services:
  #   1. TTS engine (port 8880)   — optional, gated by VOICEMODE_ENABLE_TTS
  #   2. Chatterbox (port 8890)   — voice cloning
  #   3. Whisper STT (port 2022)  — speech-to-text
  #   4. claude-stt daemon        — push-to-talk hotkey (NO port, easy to miss!)
  # If you edit this function, verify all 4 blocks survive. See: 2026-03-27 incident.

  # TTS (port 8880): Qwen3-TTS or Kokoro — disabled by default since Picard
  # uses Chatterbox directly. Enable with: VOICEMODE_ENABLE_TTS=1
  if [ "${VOICEMODE_ENABLE_TTS:-0}" = "1" ]; then
    if [ -d "$WIN_HOME/.voicemode/services/qwen3-tts/.venv" ]; then
      start_svc "qwen3-tts" "$HELPERS_DIR/start-qwen3-tts-server.sh" 8880
    else
      start_svc "kokoro" "$HELPERS_DIR/start-kokoro-server.sh" 8880
    fi
  else
    echo "  qwen3-tts skipped (not needed for voice-clone profiles)"
    echo "  Enable with: VOICEMODE_ENABLE_TTS=1 bash start-all.sh"
  fi

  # Voice cloning: prefer Chatterbox, fall back to XTTS-v2
  if [ -d "$WIN_HOME/.voicemode/services/chatterbox/.venv" ]; then
    start_svc "chatterbox" "$HELPERS_DIR/start-chatterbox-server.sh" 8890
  else
    start_svc "xtts" "$HELPERS_DIR/start-xtts-server.sh" 8890
  fi

  # STT: faster-whisper (large-v3)
  start_svc "whisper" "$HELPERS_DIR/start-whisper-server.sh" 2022

  # Readiness checks
  echo "Waiting for services..."
  if [ "${VOICEMODE_ENABLE_TTS:-0}" = "1" ]; then
    wait_for_port 8880 && echo "  TTS (8880) ready" || echo "  TTS (8880): not ready after 30s (check $LOG_DIR/)"
  fi
  wait_for_port 8890 && echo "  Clone TTS (8890) ready" || echo "  Clone TTS (8890): not ready after 30s (check $LOG_DIR/)"
  wait_for_port 2022 && echo "  STT (2022) ready" || echo "  STT (2022): not ready after 30s (check $LOG_DIR/)"

  # claude-stt daemon (push-to-talk hotkey listener)
  local stt_python="${CLAUDE_STT_PYTHON:-$WIN_HOME/.claude/plugins/cache/jarrodwatts-claude-stt/claude-stt/0.1.0/.venv/Scripts/python.exe}"
  local stt_exec="$WIN_HOME/.claude/plugins/cache/jarrodwatts-claude-stt/claude-stt/0.1.0/scripts/exec.py"
  if [ -f "$stt_exec" ]; then
    local stt_status
    stt_status=$("$stt_python" "$stt_exec" -m claude_stt.daemon status 2>&1 || true)
    if echo "$stt_status" | grep -q "is running"; then
      echo "  claude-stt daemon already running"
    else
      "$stt_python" "$stt_exec" -m claude_stt.daemon start > "$LOG_DIR/claude-stt.log" 2>&1 &
      sleep 2
      echo "  claude-stt daemon started (push-to-talk: ctrl+f12)"
    fi
  else
    echo "  claude-stt not installed"
  fi

  echo "Done. Logs in $LOG_DIR/"
}

pid_alive() {
  local pid="$1"
  # On Windows, MINGW64 kill -0 can't see native Windows processes.
  # Use tasklist as primary check, fall back to kill -0.
  if command -v tasklist &>/dev/null; then
    tasklist //FI "PID eq $pid" 2>/dev/null | grep -q "$pid"
    return $?
  fi
  kill -0 "$pid" 2>/dev/null
}

kill_pid() {
  local pid="$1" name="$2"
  if ! pid_alive "$pid"; then
    echo "  $name (PID $pid) already stopped"
    return 0
  fi
  # On Windows, use taskkill to kill the process tree (handles child processes)
  if command -v taskkill &>/dev/null; then
    taskkill //PID "$pid" //T //F >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
  else
    kill "$pid" 2>/dev/null || true
  fi
  echo "  Stopped $name (PID $pid)"
}

kill_port() {
  local port="$1" name="$2"
  if ! command -v netstat &>/dev/null; then return 0; fi
  local orphan_pid
  orphan_pid=$(netstat -ano 2>/dev/null | grep "LISTENING" | grep ":$port " | awk '{print $NF}' | head -1 || true)
  if [ -n "$orphan_pid" ] && [ "$orphan_pid" != "0" ]; then
    kill_pid "$orphan_pid" "$name (orphan on :$port)"
  fi
}

stop_services() {
  echo "Stopping voice services..."
  for svc in qwen3-tts kokoro chatterbox xtts whisper; do
    if [ -f "$PID_DIR/$svc.pid" ]; then
      pid=$(cat "$PID_DIR/$svc.pid")
      kill_pid "$pid" "$svc"
      rm -f "$PID_DIR/$svc.pid"
    fi
  done

  # Also kill any orphaned processes on the service ports (belt and suspenders)
  kill_port 8880 "qwen3-tts"
  kill_port 8890 "chatterbox"
  kill_port 2022 "whisper"

  # Stop claude-stt daemon (PID file + orphan scan)
  local stt_pid_file="$WIN_HOME/.claude/plugins/claude-stt/daemon.pid"
  if [ -f "$stt_pid_file" ]; then
    local stt_pid
    stt_pid=$(python -c "import json,sys;print(json.load(open(sys.argv[1]))['pid'])" "$stt_pid_file" 2>/dev/null || cat "$stt_pid_file" 2>/dev/null || echo "0")
    if [ "$stt_pid" != "0" ] && kill -0 "$stt_pid" 2>/dev/null; then
      kill_pid "$stt_pid" "claude-stt daemon"
    fi
    rm -f "$stt_pid_file"
  fi
  # Kill orphaned claude-stt daemons (OleMainThreadWndName = pynput keyboard hook)
  # Check both python.exe and pythonw.exe — SessionStart hook spawns as pythonw.exe
  if command -v tasklist &>/dev/null; then
    for img in python.exe pythonw.exe; do
      tasklist //V //FI "IMAGENAME eq $img" 2>/dev/null \
        | grep "OleMainThreadWndName" \
        | awk '{print $2}' \
        | while read -r orphan_pid; do
            kill_pid "$orphan_pid" "claude-stt orphan ($img)"
          done
    done
  fi

  echo "Done."
}

status_services() {
  echo "Voice services status:"

  # TTS (port 8880) — may be intentionally disabled
  if curl -sf "http://127.0.0.1:8880/health" >/dev/null 2>&1 \
  || curl -sf "http://127.0.0.1:8880/" >/dev/null 2>&1; then
    printf "  %-14s running (port 8880)\n" "qwen3-tts"
  else
    printf "  %-14s disabled (enable: VOICEMODE_ENABLE_TTS=1)\n" "qwen3-tts"
  fi

  # Voice cloning + STT
  for svc_port in "chatterbox:8890" "whisper:2022"; do
    svc="${svc_port%%:*}"
    port="${svc_port##*:}"
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1 \
    || curl -sf "http://127.0.0.1:$port/" >/dev/null 2>&1; then
      printf "  %-14s running (port %s)\n" "$svc" "$port"
    else
      printf "  %-14s stopped\n" "$svc"
    fi
  done

  # claude-stt daemon
  local stt_pid_file="$WIN_HOME/.claude/plugins/claude-stt/daemon.pid"
  if [ -f "$stt_pid_file" ]; then
    local stt_pid
    stt_pid=$(python -c "import json,sys;print(json.load(open(sys.argv[1]))['pid'])" "$stt_pid_file" 2>/dev/null || echo "0")
    if [ "$stt_pid" != "0" ] && kill -0 "$stt_pid" 2>/dev/null; then
      printf "  %-14s running (PID %s, hotkey: ctrl+f12)\n" "claude-stt" "$stt_pid"
    else
      printf "  %-14s stopped\n" "claude-stt"
    fi
  else
    printf "  %-14s stopped\n" "claude-stt"
  fi
}

case "${1:-start}" in
  start)  start_services ;;
  stop)   stop_services ;;
  status) status_services ;;
  *)      echo "Usage: $0 [start|stop|status]" ;;
esac
