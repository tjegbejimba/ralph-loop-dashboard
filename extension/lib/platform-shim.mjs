// Platform shim — Windows-specific helpers for the dashboard.
//
// POSIX call sites are not expected to import or use anything here. The
// helpers themselves are platform-agnostic where they sensibly can be
// (isAlive, pidfile read/write/remove), so they are also useful in tests
// running on POSIX. resolveBashExe() is Windows-only by definition.

import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";
import { mkdirSync } from "node:fs";

// Liveness probe. Works on Windows + POSIX. Signal 0 ("does this PID exist
// and can I signal it?") never delivers a signal; ESRCH means dead.
export function isAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM means the process exists but we lack permission to signal it.
    // For our liveness check, "exists" is what matters.
    return err.code === "EPERM";
  }
}

export function readPidFile(path) {
  try {
    if (!existsSync(path)) return null;
    const raw = readFileSync(path, "utf-8").trim();
    if (!raw) return null;
    const pid = Number(raw);
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

export function writePidFile(path, pid) {
  if (!Number.isInteger(pid) || pid <= 0) {
    throw new TypeError(`writePidFile: invalid pid ${pid}`);
  }
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, String(pid), "utf-8");
}

export function removePidFile(path) {
  try {
    unlinkSync(path);
  } catch {
    // already gone — fine
  }
}

// Locate bash.exe on Windows. Probe order:
//   1. RALPH_BASH_EXE env override (escape hatch for non-standard installs)
//   2. C:\Program Files\Git\usr\bin\bash.exe (Git for Windows, default loc)
//   3. C:\Program Files\Git\bin\bash.exe (Git for Windows, alt entry point)
//   4. "bash" on PATH (last resort; may pick up wsl-bash, hence last)
//
// Returns the first existing path, or null when none are found. Callers are
// responsible for surfacing a clear error to the user.
export function resolveBashExe() {
  const candidates = [];
  if (process.env.RALPH_BASH_EXE) {
    candidates.push(process.env.RALPH_BASH_EXE);
  }
  candidates.push(
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
    "C:\\Program Files\\Git\\bin\\bash.exe",
  );
  for (const c of candidates) {
    try {
      if (existsSync(c)) return c;
    } catch {
      // ignore and continue
    }
  }
  // Fall back to bare "bash" — Node will resolve it via PATH at spawn time.
  return "bash";
}

// Convert a Windows path (C:\foo\bar) to a POSIX-style path that bash
// understands (/c/foo/bar). Pass-through for paths that are already POSIX.
export function toBashPath(winPath) {
  if (!winPath) return winPath;
  if (!/^[A-Za-z]:\\/.test(winPath)) return winPath;
  const drive = winPath[0].toLowerCase();
  const rest = winPath.slice(2).replace(/\\/g, "/");
  return `/${drive}${rest}`;
}
