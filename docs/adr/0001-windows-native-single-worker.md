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

Worker registration remains the only startup-success signal. Setup can
legitimately take longer than the controller's 30-second startup window, so
`launch.sh` atomically records phase changes in the run's `startup.json`.
Each new phase renews the 30-second inactivity deadline, while a five-minute
hard limit prevents an unhealthy launcher from extending startup forever. A
status entry counts as registration only when it carries positive `workerId`
and `pid` fields. The controller verifies the installed launch-protocol marker
before spawning, so an extension/script version skew fails with a refresh
instruction rather than silently losing progress and diagnostics.

Launcher output is written to the run's `launcher.log`; controller errors
include only its final 16 KiB. Redirection happens inside `launch.sh` because
passing inherited file handles to detached Git Bash can prevent the script from
starting at all.

Windows does not deliver Node's `SIGTERM` to Git Bash as a trappable POSIX
signal. A timeout can therefore bypass Bash's `EXIT` trap and strand both setup
locks. The controller terminates the full Windows process tree, waits for exit,
and then removes only setup locks stamped with that launch's random token.
Missing or mismatched tokens are retained and reported fail-closed.
The Windows launcher pidfile is also created exclusively and removed only when
it still contains the exiting launcher's PID; a concurrent launcher cannot
overwrite or delete another launcher's process identity.

Linked worktrees add a second Windows path constraint. Git for Windows returns
both `git rev-parse --git-common-dir` and `git rev-parse --git-path
info/exclude` as drive-letter absolute paths (`C:/...`). The installer and
launcher must treat both `/...` and `[A-Za-z]:/...` as absolute before placing
the shared setup lock or updating the common exclude file. Prefixing the
coordinator worktree path creates an invalid mixed path; a misplaced exclude
leaves the worker's `.ralph` link unignored, so worker cleanliness preflight
halts before registration.

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

The single-worker decision is gated to Windows only. Progress-aware startup and
per-run launcher diagnostics apply on every platform; process-tree termination
is Windows-specific.
