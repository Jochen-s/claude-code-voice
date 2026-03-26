#!/usr/bin/env node
/**
 * Stop hook: Extracts text between TTS markers and speaks it via local TTS.
 * Reads Claude Code output, finds tts-marked text, sends to the active TTS engine,
 * and plays the resulting audio.
 *
 * Markers: «tts»...«/tts» (guillemet-wrapped)
 *
 * Install: Add to settings.json as a Stop hook.
 * Config: Set VOICEMODE_PROFILES to the path of voice-profiles.json,
 *         or place this file alongside voice-profiles.json.
 */

'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
// child_process: spawnSync used in playAudio, spawn used in main (hook mode)
const crypto = require('crypto');

// TTS marker pattern — create fresh each use to avoid lastIndex drift (HC-fix: LC-2)
const TTS_OPEN = '\u00ABtts\u00BB';
const TTS_CLOSE = '\u00AB/tts\u00BB';

function createTtsRegex() {
  return new RegExp(
    TTS_OPEN.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
    '([\\s\\S]*?)' +
    TTS_CLOSE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'),
    'g'
  );
}

// Config — profiles path supports env override for when hook is installed to ~/.claude/hooks/
const PROFILES_PATH = process.env.VOICEMODE_PROFILES
  || path.join(__dirname, 'voice-profiles.json');
const DEFAULT_VOICE = process.env.CLAUDE_VOICE || process.env.VOICEMODE_VOICES || 'vivian';
const MAX_TTS_LENGTH = 2000; // Guard against runaway TTS blocks
const DEBUG = process.env.TTS_HOOK_DEBUG === '1'; // Set TTS_HOOK_DEBUG=1 for diagnostics

const HOOK_LOG_FILE = path.join(process.env.TEMP || '/tmp', 'claude-tts-hook.log');

function dbg(msg) {
  if (DEBUG) process.stderr.write(`tts-hook[dbg]: ${msg}\n`);
}

// Hook-level logging: always writes to file (separate from worker log)
function hookLog(msg) {
  try {
    const ts = new Date().toISOString();
    fs.appendFileSync(HOOK_LOG_FILE, `[${ts}] ${msg}\n`);
  } catch { /* ignore */ }
}

// Engine endpoint defaults
const ENGINE_DEFAULTS = {
  'qwen3-tts': { host: '127.0.0.1', port: 8880, path: '/v1/audio/speech' },
  chatterbox:  { host: '127.0.0.1', port: 8890, path: '/v1/audio/speech' },
  kokoro:      { host: '127.0.0.1', port: 8880, path: '/v1/audio/speech' },
  xtts:        { host: '::1',       port: 8890, path: '/v1/audio/speech' },
};

// Cache profiles for the lifetime of this hook invocation
let _profilesCache = null;

function loadProfiles() {
  if (_profilesCache) return _profilesCache;
  try {
    _profilesCache = JSON.parse(fs.readFileSync(PROFILES_PATH, 'utf8'));
  } catch (err) {
    process.stderr.write(`tts-hook: could not read profiles: ${err.message}\n`);
    _profilesCache = null;
  }
  return _profilesCache;
}

function getVoiceConfig() {
  const profiles = loadProfiles();
  if (!profiles) return { engine: 'qwen3-tts', voice: DEFAULT_VOICE };

  const active = process.env.CLAUDE_VOICE || profiles.active || 'default';
  const profile = profiles.profiles[active] || profiles.profiles.default;
  if (!profile) return { engine: 'qwen3-tts', voice: DEFAULT_VOICE };

  return profile;
}

function getEndpoint(engine) {
  const profiles = loadProfiles();
  // Try to get endpoint from profiles.engines config
  if (profiles && profiles.engines && profiles.engines[engine]) {
    const cfg = profiles.engines[engine];
    if (cfg.endpoint) {
      try {
        const url = new URL(cfg.endpoint);
        return {
          host: url.hostname,
          port: parseInt(url.port, 10) || ENGINE_DEFAULTS[engine]?.port || 8880,
          path: url.pathname.replace(/\/$/, '') + '/audio/speech',
        };
      } catch { /* fall through */ }
    }
  }
  // Fall back to engine defaults
  return ENGINE_DEFAULTS[engine] || ENGINE_DEFAULTS.kokoro;
}

function expandTilde(p) {
  if (typeof p === 'string' && p.startsWith('~/')) {
    return path.join(process.env.HOME || process.env.USERPROFILE || '', p.slice(2));
  }
  return p;
}

function playAudio(tmpFile) {
  const { spawnSync } = require('child_process');

  if (process.platform === 'win32') {
    // Windows: use Python winsound — synchronous to avoid callback/event-loop issues
    // in detached worker context. spawnSync blocks reliably until audio finishes.
    const result = spawnSync('python.exe', ['-c',
      'import sys,winsound;winsound.PlaySound(sys.argv[1],winsound.SND_FILENAME)',
      tmpFile], { stdio: 'inherit', windowsHide: true, timeout: 30000 });
    if (result.error) dbg(`playAudio: error: ${result.error.message}`);
    if (result.status !== 0) dbg(`playAudio: exit code ${result.status}`);
  } else {
    // Linux: try ffplay first, fall back to aplay
    const r = spawnSync('ffplay', ['-nodisp', '-autoexit', '-loglevel', 'quiet', tmpFile],
      { stdio: 'inherit', timeout: 30000 });
    if (r.error || r.status !== 0) {
      spawnSync('aplay', ['-q', tmpFile], { stdio: 'inherit', timeout: 30000 });
    }
  }

  return Promise.resolve();
}

function speakText(text, voiceConfig) {
  return new Promise((resolve) => {
    const engine = voiceConfig.engine || 'kokoro';
    const endpoint = getEndpoint(engine);
    const voice = voiceConfig.voice || DEFAULT_VOICE;

    // Truncate to prevent runaway TTS
    const input = text.trim().slice(0, MAX_TTS_LENGTH);
    if (!input) return resolve(null);

    // All engines use OpenAI-compatible /v1/audio/speech
    const reqPath = endpoint.path;
    const profiles = loadProfiles();
    const engineCfg = (profiles && profiles.engines && profiles.engines[engine]) || {};

    const body = {
      model: engineCfg.model || 'tts-1',
      input,
      voice,
      response_format: 'wav',
      speed: voiceConfig.speed || 1.0,
    };

    // Chatterbox supports extra parameters (exaggeration, cfg_weight, temperature)
    if (engine === 'chatterbox') {
      const defaults = (engineCfg.parameters) || {};
      body.exaggeration = voiceConfig.exaggeration ?? defaults.exaggeration ?? 0.5;
      body.cfg_weight = voiceConfig.cfg_weight ?? defaults.cfg_weight ?? 0.5;
      body.temperature = voiceConfig.temperature ?? defaults.temperature ?? 0.8;
    }

    const payload = JSON.stringify(body);
    const contentType = 'application/json';

    dbg(`speakText: requesting ${endpoint.host}:${endpoint.port}${reqPath} (${input.length} chars)`);
    const req = http.request({
      hostname: endpoint.host,
      port: endpoint.port,
      path: reqPath,
      method: 'POST',
      headers: {
        'Content-Type': contentType,
        'Content-Length': Buffer.byteLength(payload),
      },
      timeout: engine === 'chatterbox' ? 30000 : 10000, // Chatterbox voice cloning is slower
    }, (res) => {
      if (res.statusCode !== 200) {
        dbg(`speakText: HTTP ${res.statusCode} from TTS`);
        res.resume(); // drain
        return resolve(null);
      }

      // Write to temp file, play, then clean up
      const tmpFile = path.join(
        process.env.TEMP || '/tmp',
        `claude-tts-${crypto.randomBytes(8).toString('hex')}.wav`
      );
      const ws = fs.createWriteStream(tmpFile);
      ws.on('error', (err) => {
        dbg(`speakText: write error: ${err.message}`);
        try { fs.unlinkSync(tmpFile); } catch { /* ignore */ }
        resolve(null);
      });
      res.pipe(ws);
      ws.on('finish', () => {
        const size = fs.statSync(tmpFile).size;
        dbg(`speakText: audio ${size} bytes, playing`);
        playAudio(tmpFile).then(() => {
          dbg('speakText: playback done');
          // Always clean up temp file
          try { fs.unlinkSync(tmpFile); } catch { /* ignore */ }
          resolve(tmpFile);
        });
      });
    });

    req.on('error', (err) => {
      dbg(`speakText: connection error: ${err.message}`);
      resolve(null);
    });
    req.on('timeout', () => { dbg('speakText: request timeout'); req.destroy(); resolve(null); });

    req.write(payload);
    req.end();
  });
}

function extractTtsText(content) {
  const regex = createTtsRegex(); // Fresh regex each call — no lastIndex drift
  const matches = [];
  let match;
  while ((match = regex.exec(content)) !== null) {
    const text = match[1].trim();
    if (text.length > 0) matches.push(text);
  }
  return matches;
}

function readLastAssistantMessage(transcriptPath) {
  if (!transcriptPath || !fs.existsSync(transcriptPath)) {
    dbg(`no transcript: ${transcriptPath}`);
    return '';
  }

  const MAX_TAIL = 256 * 1024; // Increased: transcript splits text/tool_use into separate entries
  try {
    const stat = fs.statSync(transcriptPath);
    const fd = fs.openSync(transcriptPath, 'r');
    const readSize = Math.min(stat.size, MAX_TAIL);
    const buf = Buffer.alloc(readSize);
    fs.readSync(fd, buf, 0, readSize, Math.max(0, stat.size - readSize));
    fs.closeSync(fd);

    const raw = buf.toString('utf8');
    const lines = raw.split('\n').filter(l => l.trim());
    dbg(`transcript ${(stat.size / 1024).toFixed(0)}KB, ${lines.length} lines, tail ${(readSize / 1024).toFixed(0)}KB`);

    // Drop first line if we started mid-file (likely truncated JSON)
    if (stat.size > MAX_TAIL && lines.length > 0) {
      lines.shift();
    }

    // Scan backward for the last assistant entry with TTS markers.
    // Claude Code splits text/tool_use/thinking into separate JSONL entries,
    // so the last entry is often a tool_use with no text content.
    let skipped = 0;
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const entry = JSON.parse(lines[i]);
        if (entry.role === 'assistant' || entry.type === 'assistant') {
          let text = '';
          const content = entry.content || (entry.message && entry.message.content);
          if (typeof content === 'string') text = content;
          else if (Array.isArray(content)) {
            text = content
              .filter(b => b && b.type === 'text')
              .map(b => b.text)
              .join('\n');
          }
          // Skip entries with no text or no TTS markers (tool_use, thinking blocks)
          if (text && text.includes(TTS_OPEN)) {
            dbg(`found TTS in entry ${i} (skipped ${skipped} assistant entries)`);
            return text;
          }
          skipped++;
        }
      } catch { /* skip malformed line */ }
    }
    dbg(`no TTS markers found after scanning ${skipped} assistant entries`);
  } catch (err) {
    process.stderr.write(`tts-hook: transcript read error: ${err.message}\n`);
  }
  return '';
}

// Dedup: prevent speaking the same text twice in a row per session
function getSpokenHashPath(transcriptPath) {
  const sessionHash = crypto.createHash('md5').update(transcriptPath || 'default').digest('hex').slice(0, 12);
  return path.join(process.env.TEMP || '/tmp', `claude-tts-spoken-${sessionHash}.txt`);
}

function wasAlreadySpoken(texts, transcriptPath) {
  const contentHash = crypto.createHash('md5').update(texts.join('|')).digest('hex');
  const hashFile = getSpokenHashPath(transcriptPath);
  try {
    const lastHash = fs.readFileSync(hashFile, 'utf8').trim();
    return lastHash === contentHash;
  } catch { return false; }
}

function markAsSpoken(texts, transcriptPath) {
  const contentHash = crypto.createHash('md5').update(texts.join('|')).digest('hex');
  const hashFile = getSpokenHashPath(transcriptPath);
  try { fs.writeFileSync(hashFile, contentHash, 'utf8'); } catch { /* ignore */ }
}

// ---------------------------------------------------------------------------
// Playback lock: serialize TTS across all sessions for this user
// ---------------------------------------------------------------------------
const TTS_LOCK_FILE = path.join(process.env.TEMP || '/tmp', 'claude-tts-playback.lock');
const LOCK_POLL_MS = 150;     // Poll interval (was 300 — halved for faster acquisition)
const LOCK_MAX_WAIT_MS = 60000; // Give up after 60s (stale safety net)
const LOCK_MAX_AGE_MS = 300000; // Force-steal locks older than 5 min (allows multi-segment Chatterbox jobs)

// Tri-state: 'alive' | 'dead' | 'unknown' (EPERM = can't tell, don't steal)
function processLiveness(pid) {
  try { process.kill(pid, 0); return 'alive'; } catch (err) {
    return err.code === 'ESRCH' ? 'dead' : 'unknown';
  }
}

// Shared buffer for Atomics.wait — non-spinning sleep in sync context
// Guard: SharedArrayBuffer may be unavailable in older Node.js or restricted contexts
let _sleepBuf;
try {
  _sleepBuf = new Int32Array(new SharedArrayBuffer(4));
} catch {
  _sleepBuf = null;
}

function syncSleep(ms) {
  if (_sleepBuf) {
    Atomics.wait(_sleepBuf, 0, 0, ms);
  } else {
    // Fallback: spawnSync-based sleep (blocks without spinning)
    // node -e '' exits in ~30ms — must use setTimeout to actually sleep for ms
    const { spawnSync } = require('child_process');
    spawnSync(process.execPath, ['-e', `setTimeout(()=>{},${ms})`], { timeout: ms + 500 });
  }
}

function acquireLock() {
  const start = Date.now();
  while (Date.now() - start < LOCK_MAX_WAIT_MS) {
    try {
      // O_EXCL: atomic create-if-not-exists
      const fd = fs.openSync(TTS_LOCK_FILE, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY);
      fs.writeSync(fd, JSON.stringify({ pid: process.pid, ts: Date.now() }));
      fs.closeSync(fd);
      dbg(`lock acquired (PID ${process.pid})`);
      return true;
    } catch {
      // Lock exists — check if holder is stale
      try {
        const raw = fs.readFileSync(TTS_LOCK_FILE, 'utf8').trim();
        let holder, lockTs;
        try {
          const lockData = JSON.parse(raw);
          holder = lockData.pid;
          lockTs = lockData.ts || 0;
        } catch {
          // Backward compat: old bare-PID format or partial write
          const parsed = parseInt(raw, 10);
          if (!raw || isNaN(parsed)) {
            // Empty or unparseable — treat as transient, sleep and retry
            dbg('lock file empty or unparseable, waiting for writer to finish');
            syncSleep(LOCK_POLL_MS);
            continue;
          }
          holder = parsed;
          lockTs = 0; // unknown age — rely on PID liveness only
        }
        const lockAge = Date.now() - lockTs;
        const liveness = processLiveness(holder);

        // Steal only if holder is confirmed dead (ESRCH)
        if (liveness === 'dead') {
          dbg(`stale lock from dead PID ${holder} (age ${(lockAge / 1000).toFixed(0)}s), stealing`);
          try { fs.unlinkSync(TTS_LOCK_FILE); } catch { /* race ok */ }
          syncSleep(LOCK_POLL_MS); // avoid tight retry if unlink races with another stealer
          continue;
        }

        // Force-steal only if ancient AND liveness is unknown (EPERM / cross-user)
        // Never force-steal a lock held by a confirmed-alive process
        if (lockAge > LOCK_MAX_AGE_MS && liveness === 'unknown') {
          dbg(`ancient lock (${(lockAge / 1000).toFixed(0)}s old, PID ${holder} liveness unknown), force-stealing`);
          try { fs.unlinkSync(TTS_LOCK_FILE); } catch { /* race ok */ }
          syncSleep(LOCK_POLL_MS); // avoid tight retry if unlink races with another stealer
          continue;
        }
      } catch (err) {
        // Lock file disappeared — retry after sleep to avoid tight spin
        if (err.code === 'ENOENT') { syncSleep(LOCK_POLL_MS); continue; }
        // Truly unexpected error — sleep and retry (don't blindly unlink)
        dbg(`lock read error: ${err.code || err.message}, retrying`);
        syncSleep(LOCK_POLL_MS);
        continue;
      }
      // Active holder — sleep without spinning
      syncSleep(LOCK_POLL_MS);
    }
  }
  dbg('lock timeout — skipping playback (overlap prevention)');
  return false;
}

function refreshLock() {
  // Update timestamp to signal we're still actively playing — prevents age-based steal
  try {
    fs.writeFileSync(TTS_LOCK_FILE, JSON.stringify({ pid: process.pid, ts: Date.now() }));
  } catch { /* lock was stolen or removed — releaseLock will detect */ }
}

let _lockReleased = false;

function releaseLock() {
  if (_lockReleased) return; // guard against double-release (finally + process.on('exit'))
  try {
    // Only release if we own it
    const raw = fs.readFileSync(TTS_LOCK_FILE, 'utf8').trim();
    let holder;
    try {
      holder = JSON.parse(raw).pid;
    } catch {
      const parsed = parseInt(raw, 10); // Backward compat with old bare-PID format
      holder = isNaN(parsed) ? null : parsed;
    }
    if (holder === process.pid) {
      fs.unlinkSync(TTS_LOCK_FILE);
      _lockReleased = true;
      dbg('lock released');
    } else if (holder === null) {
      dbg('lock file corrupted (unparseable) — removing');
      try { fs.unlinkSync(TTS_LOCK_FILE); } catch { /* race ok */ }
      _lockReleased = true;
    } else {
      dbg(`lock now held by PID ${holder} — not ours, leaving intact`);
      _lockReleased = true; // prevent repeated log on exit handler
    }
  } catch { /* already gone */ _lockReleased = true; }
}

// ---------------------------------------------------------------------------
// Worker mode: spawned detached to handle TTS without blocking the hook
// ---------------------------------------------------------------------------
async function workerMain() {
  const jobFile = process.argv[3];
  if (!jobFile) process.exit(0);

  let job;
  try {
    job = JSON.parse(fs.readFileSync(jobFile, 'utf8'));
    fs.unlinkSync(jobFile); // Clean up immediately
  } catch {
    process.exit(0);
  }

  const { texts, voiceConfig, transcriptPath } = job;
  if (!texts || texts.length === 0) process.exit(0);

  dbg(`worker: speaking ${texts.length} segment(s)`);

  // Acquire playback lock — serializes TTS across all sessions
  // CRITICAL: if lock fails, skip playback entirely (never overlap)
  const gotLock = acquireLock();
  if (!gotLock) {
    dbg('worker: lock acquisition failed, skipping playback to prevent overlap');
    process.exit(0);
  }

  // Safety net: release lock if worker exits unexpectedly (crash, SIGTERM, etc.)
  // Registered AFTER lock is acquired — only clean up what we own
  process.on('exit', () => { releaseLock(); });

  try {
    for (const text of texts) {
      dbg(`worker speaking: "${text.slice(0, 60)}..."`);
      await speakText(text, voiceConfig);
      refreshLock(); // keep lock timestamp fresh between segments
    }
  } finally {
    releaseLock();
  }

  markAsSpoken(texts, transcriptPath);
  dbg('worker done');
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Hook mode: fast extract + spawn detached worker
// ---------------------------------------------------------------------------
function main() {
  hookLog('main() entered');
  let input = '';
  try {
    input = fs.readFileSync(0, 'utf8');
  } catch (err) {
    hookLog(`BAIL: stdin read failed: ${err.message}`);
    process.exit(0);
  }

  let hookData;
  try {
    hookData = JSON.parse(input);
  } catch (err) {
    hookLog(`BAIL: stdin JSON parse failed: ${err.message}`);
    process.exit(0);
  }

  const transcriptPath = hookData.transcript_path;
  hookLog(`hook fired, transcript: ${transcriptPath}`);
  dbg(`Stop hook fired, transcript: ${transcriptPath}`);

  const lastMessage = readLastAssistantMessage(transcriptPath);
  if (!lastMessage) { hookLog('BAIL: no assistant message found'); dbg('bail: no assistant message found'); process.exit(0); }

  // Quick check: bail early if no TTS markers present (avoid unnecessary work)
  if (!lastMessage.includes(TTS_OPEN)) { hookLog(`BAIL: no TTS markers in message (${lastMessage.length} chars)`); dbg('bail: message has no TTS markers'); process.exit(0); }

  const ttsTexts = extractTtsText(lastMessage);
  if (ttsTexts.length === 0) { hookLog('BAIL: regex extracted 0 TTS blocks'); dbg('bail: regex extracted 0 TTS blocks'); process.exit(0); }
  hookLog(`extracted ${ttsTexts.length} block(s): ${ttsTexts.map(t => t.slice(0, 40)).join(' | ')}`);
  dbg(`extracted ${ttsTexts.length} TTS block(s): ${ttsTexts.map(t => t.slice(0, 40) + '...').join(' | ')}`);

  // Dedup: skip if we already spoke this exact content
  if (wasAlreadySpoken(ttsTexts, transcriptPath)) { hookLog('BAIL: dedup — already spoken'); dbg('bail: dedup — already spoken'); process.exit(0); }

  // Mark as spoken immediately (before worker starts) to prevent duplicate fires
  markAsSpoken(ttsTexts, transcriptPath);

  // Load voice config
  const voiceConfig = getVoiceConfig();
  dbg(`voice: engine=${voiceConfig.engine}, voice=${voiceConfig.voice}`);

  // Write job file for worker
  const jobFile = path.join(
    process.env.TEMP || '/tmp',
    `claude-tts-job-${crypto.randomBytes(8).toString('hex')}.json`
  );
  try {
    fs.writeFileSync(jobFile, JSON.stringify({
      texts: ttsTexts,
      voiceConfig,
      transcriptPath,
    }), 'utf8');
  } catch (err) {
    process.stderr.write(`tts-hook: failed to write job file: ${err.message}\n`);
    process.exit(0);
  }

  // Spawn detached worker — hook exits immediately, worker handles TTS
  // Windows/MINGW64: stdio:'ignore' silently prevents detached child execution.
  // Must use real file descriptors for stdout/stderr.
  const { spawn } = require('child_process');
  const nullOut = fs.openSync(process.platform === 'win32' ? 'NUL' : '/dev/null', 'w');
  // Stderr → log file for debugging worker failures (NUL swallows errors silently)
  const logFile = path.join(process.env.TEMP || '/tmp', 'claude-tts-worker.log');
  const errFd = fs.openSync(logFile, 'a');
  const worker = spawn(process.execPath, [__filename, '--speak-worker', jobFile], {
    detached: true,
    stdio: ['ignore', nullOut, errFd],
    windowsHide: true,
    env: { ...process.env, TTS_HOOK_DEBUG: '1' },
  });
  worker.unref();
  fs.closeSync(nullOut);
  fs.closeSync(errFd);
  hookLog(`spawned worker PID ${worker.pid}`);
  dbg(`spawned worker PID ${worker.pid}, exiting hook`);

  process.exit(0);
}

// Entry point: dispatch based on mode
if (process.argv.includes('--speak-worker')) {
  workerMain().catch((err) => {
    process.stderr.write(`tts-hook worker: ${err.message}\n`);
    process.exit(0);
  });
} else {
  main();
}
