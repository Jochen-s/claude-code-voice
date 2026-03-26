#!/usr/bin/env node
/**
 * stt-dedup-guard.js — SessionStart hook
 * Detects and kills duplicate claude-stt daemon process chains.
 *
 * On Windows Python 3.12+, a venv's pythonw.exe is a launcher that spawns
 * the base interpreter as a child. So one daemon = TWO processes:
 *   - Venv launcher (plugin venv pythonw.exe)
 *   - Base interpreter (C:\venv\Python312\pythonw.exe, child of launcher)
 *
 * This guard counts independent chains (roots), not individual processes.
 * A "root" is an STT daemon whose parent is NOT another STT daemon.
 * If there are multiple roots, it keeps one chain and kills the rest.
 *
 * Runs on every SessionStart (startup + resume). Typical: ~300-500ms
 * (PowerShell cold start dominates). No network I/O.
 */

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

/**
 * Validate CLAUDE_STT_PYTHON env var — warn loudly if path is stale
 * (e.g., after plugin version update from 0.1.0 → 0.2.0).
 */
function validateSttPython() {
  const sttPython = process.env.CLAUDE_STT_PYTHON;
  if (!sttPython) return;

  if (!fs.existsSync(sttPython)) {
    // Try to auto-resolve: find latest version in plugin cache
    const cacheBase = path.join(
      process.env.USERPROFILE || process.env.HOME || '',
      '.claude', 'plugins', 'cache', 'jarrodwatts-claude-stt', 'claude-stt'
    );
    let resolved = null;
    try {
      const versions = fs.readdirSync(cacheBase)
        .filter(d => fs.statSync(path.join(cacheBase, d)).isDirectory())
        .sort();
      if (versions.length > 0) {
        const latest = versions[versions.length - 1];
        const candidate = path.join(cacheBase, latest, '.venv', 'Scripts', 'python.exe');
        if (fs.existsSync(candidate)) {
          resolved = candidate;
        }
      }
    } catch (e) { /* cache dir may not exist */ }

    const msg = resolved
      ? `CLAUDE_STT_PYTHON points to missing "${sttPython}". Found newer: "${resolved}". Update settings.json env.CLAUDE_STT_PYTHON.`
      : `CLAUDE_STT_PYTHON points to missing "${sttPython}". Voice input may fail. Update settings.json after plugin update.`;
    process.stderr.write(`stt-dedup-guard: WARNING: ${msg}\n`);
    console.log(JSON.stringify({ result: `STT WARNING: ${msg}` }));
  }
}

function main() {
  if (process.platform !== 'win32') return;

  validateSttPython();

  try {
    // Get all pythonw.exe processes with PIDs, parent PIDs, and command lines
    const raw = execFileSync('powershell', [
      '-NoProfile',
      '-Command',
      "Get-CimInstance Win32_Process -Filter \"name='pythonw.exe' AND CommandLine LIKE '%claude_stt%'\" | Select-Object ProcessId,ParentProcessId,CommandLine | ConvertTo-Json"
    ], { encoding: 'utf-8', timeout: 4000 });

    if (!raw || !raw.trim()) {
      return;
    }

    let processes = JSON.parse(raw);
    if (!Array.isArray(processes)) {
      processes = [processes];
    }

    // Filter to only claude-stt daemon processes (belt + suspenders with WMI filter above)
    const sttDaemons = processes.filter(p =>
      p && typeof p.ProcessId === 'number' && p.ProcessId > 0 &&
      p.CommandLine && p.CommandLine.includes('claude_stt.daemon')
    );

    if (sttDaemons.length === 0) {
      return;
    }

    // Build a set of STT daemon PIDs for fast lookup
    const sttPids = new Set(sttDaemons.map(p => p.ProcessId));

    // Find "root" daemons: those whose parent is NOT another STT daemon.
    // A venv launcher's child (the base interpreter) has a parent that IS
    // an STT daemon, so it won't be counted as a root.
    const roots = sttDaemons.filter(p => !sttPids.has(p.ParentProcessId));

    if (roots.length <= 1) {
      // 0 or 1 independent daemon chain — healthy state
      return;
    }

    // Multiple independent chains. Keep one chain, kill the rest.
    // Prefer a chain rooted in the plugin venv (case-insensitive).
    const pluginRoots = roots.filter(p => {
      const cl = p.CommandLine.toLowerCase();
      return cl.includes('plugins/cache') || cl.includes('plugins\\cache');
    });

    const keeper = pluginRoots.length > 0 ? pluginRoots[0] : roots[0];
    const keeperPid = keeper.ProcessId;

    // Build parent→children adjacency map for full subtree traversal
    const childrenOf = new Map();
    for (const d of sttDaemons) {
      if (!childrenOf.has(d.ParentProcessId)) {
        childrenOf.set(d.ParentProcessId, []);
      }
      childrenOf.get(d.ParentProcessId).push(d.ProcessId);
    }

    // BFS: collect full subtree of each non-keeper root (children first for kill order)
    const toKill = [];
    for (const root of roots) {
      if (root.ProcessId === keeperPid) continue;

      // BFS to find all descendants (arbitrary depth)
      const descendants = [];
      const queue = [root.ProcessId];
      while (queue.length > 0) {
        const pid = queue.shift();
        const children = childrenOf.get(pid) || [];
        for (const child of children) {
          if (child !== keeperPid) {
            descendants.push(child);
            queue.push(child);
          }
        }
      }

      // Kill children first (deepest first via reverse), then root
      // This prevents orphan respawning and ensures clean teardown
      descendants.reverse();
      toKill.push(...descendants, root.ProcessId);
    }

    if (toKill.length > 0) {
      // Batch kill: single taskkill call with multiple /PID args
      // Reduces TOCTOU window and fits within timeout budget
      const args = ['/F'];
      for (const pid of toKill) {
        args.push('/PID', String(pid));
      }
      try {
        execFileSync('taskkill', args, {
          encoding: 'utf-8',
          timeout: 3000
        });
      } catch (e) {
        // Some processes may have already exited — partial success is OK
      }

      console.log(JSON.stringify({
        result: `STT dedup: killed ${toKill.length} process(es) from ${roots.length - 1} duplicate chain(s) (PIDs: ${toKill.join(', ')}), kept chain rooted at PID ${keeperPid}`
      }));
    }
  } catch (e) {
    // Don't block session start, but surface the error for diagnostics
    process.stderr.write(`stt-dedup-guard: ${e.message || e}\n`);
  }
}

main();
