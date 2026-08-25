# Windows native mode is single-worker; reject parallelism > 1

When the dashboard launches Bash detached on Windows from a non-Bash parent
(Node.js / `conhost.exe`), Cygwin's fork emulation crashes:

```
bash 1026 dofork: child 1027 - died waiting for dll loading, errno 11
```

We sidestep this by running `launch.sh --foreground`, which skips the
`nohup ... &` path inside the launcher. Foreground mode runs **one** worker.
The Node controller invokes Git Bash with `launch.sh` as the script argument
(`bash.exe /c/.../.ralph/launch.sh --foreground`), not through `bash -lc`.
The login-shell path runs profile startup commands before `launch.sh`; with
detached ignored stdio on native Windows, that path can remain alive without
ever reaching worker registration.

Linked worktrees add a second Windows path constraint. Git for Windows returns
`git rev-parse --git-common-dir` as a drive-letter absolute path (`C:/...`).
The launcher must treat both `/...` and `[A-Za-z]:/...` as absolute before
placing its shared setup lock; prefixing the coordinator worktree path creates
an invalid mixed path and prevents worker registration.

The dashboard supports three plausible behaviours when a Windows user requests
`parallelism > 1`: silently clamp to 1, clamp to 1 with a UI warning, or
hard-error the Start. We picked **hard error**.

A silent clamp is dishonest — a user who set `parallelism: 4` and saw "loop
started" would believe they were getting 4× throughput and discover the truth
only by puzzling at queue drain rate hours later. A surfaced warning would
require new UI plumbing in `extension/content/main.js` (the existing Start
handler at line ~1238 only branches on `res.ok`/`res.error` and would silently
drop a `res.warning` field today). The Cygwin fork limit is a hard platform
constraint, not a soft preference, so a hard error is the honest signal: the
user makes a deliberate choice to drop parallelism to 1 (and now knows they're
in single-worker mode) or switches to WSL2.

The error message names the cause and the workaround
(`extension/main.mjs:startLoopWindows`):

> Windows native mode runs one worker at a time (Cygwin fork limitation).
> Reduce parallelism to 1 in Run options, or use WSL2 for parallel workers.

This decision is gated to Windows only; POSIX paths are untouched.
