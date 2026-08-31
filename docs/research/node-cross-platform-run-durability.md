# Cross-platform Node run durability and process supervision

**Research question:** Which dependency-light Node.js primitives can preserve
Ralph's Run guarantees on native Windows and macOS without Bash, a daemon, or a
database?

## Conclusion

Most of the **Run data plane** can be implemented with Node built-ins:

- serialize each Run's mutations through one in-process queue and one
  cross-process lock acquired with `fs.mkdir()` or `fs.open(..., 'wx')`;
- assign sequence numbers while holding that lock;
- append one complete event, explicitly sync it, and recover by validating and
  replaying only a contiguous sequence;
- replace snapshots with a synced same-directory temporary file followed by
  `fs.rename()`;
- persist cancellation intent and progress heartbeats as ordinary Run
  events/snapshots.

Those are application protocols built from small primitives, not guarantees
provided by `appendFile()` or `rename()` alone. Node explicitly warns that
concurrent filesystem modifications are not synchronized or threadsafe.[^node-fs]
POSIX defines append positioning for each `write()`, but permits partial writes;
the `PIPE_BUF` non-interleaving rule applies only to pipes and FIFOs, not regular
event files.[^posix-write]

Three guarantees are **not established as equivalent by the current primary
sources**:

1. Node's Windows rename path is not documented as an atomic, power-loss-durable
   replacement protocol. Microsoft documents replacement and a write-through
   option at the Win32 layer, but separately identifies a transacted API; Node
   exposes neither a transactional rename contract nor a portable parent
   directory sync contract.[^node-rename][^movefileex]
2. Pure Node has no documented cross-platform process-tree containment
   primitive. macOS can use POSIX process groups, subject to a Node integration
   prototype; Windows requires `taskkill /T` or a small native Job Object
   helper.[^node-detached][^posix-kill][^taskkill][^job-objects]
3. A PID or expired heartbeat cannot safely prove lock ownership has ended.
   PID reuse, suspension, event-loop stalls, and the crash window between lock
   creation and owner metadata require conservative fencing and recovery tests.

Therefore, a dependency-light Node controller is viable, but **the research
does not support claiming full Windows/macOS equivalence yet**. The data-plane
protocol should be implemented behind explicit durability tests. Strong
Windows process containment needs either an OS command (`taskkill`) or a narrow
native dependency; strong automatic stale-lock takeover needs fencing evidence
stronger than PID plus wall-clock age.

## Scope and guarantee levels

This report assumes a local APFS volume on macOS or local NTFS volume on Windows.
Network filesystems, removable media, FAT variants, and multiple machines
sharing one Run directory are out of scope.

The findings use three labels:

- **Documented**: guaranteed by current Node, POSIX, or Win32 documentation.
- **Protocol guarantee**: provided only when Ralph follows the complete
  sequencing/recovery protocol described here.
- **Prototype required**: primary sources do not establish equivalent behavior,
  so Ralph must test the exact Node/OS/filesystem combination.

Atomic reader visibility and crash durability are separate properties. A reader
that never observes half of a rename can still observe old data after power
loss. Likewise, `FileHandle.sync()` requests that data be synchronized, but it
does not by itself document persistence of the directory entry changed by a
subsequent rename.[^node-sync][^posix-fsync]

## Capability matrix

| Capability | Dependency-light primitive | macOS | Windows | Finding |
| --- | --- | --- | --- | --- |
| Exclusive Run mutation | `mkdir(lockDir)` or `open(lock, 'wx')` | Documented exclusive namespace create | Documented create-new failure when the name exists | Good acquisition primitive on local filesystems; recovery is separate |
| Sequenced event writes | lock + awaited full write + `FileHandle.sync()` | Protocol guarantee | Protocol guarantee | Do not infer record atomicity from regular-file append |
| Atomic snapshot visibility | same-directory temp + sync + close + `rename()` | POSIX replacement visibility is documented | Replace-existing is documented, atomic visibility is not | Prototype Windows readers/replacement |
| Power-loss-durable snapshot | file sync + rename + parent metadata sync | POSIX primitives exist; exact Node/macOS storage result needs fault testing | No documented portable Node directory-sync recipe | Prototype required on both target filesystems |
| Crash recovery | validate snapshot, replay contiguous events, quarantine invalid tail | Equivalent application logic | Equivalent application logic | Fully feasible in Node |
| Immediate child supervision | `spawn()`, `'error'`, `'exit'`/`'close'`, `AbortSignal` | Documented | Documented | Feasible |
| Process-tree supervision | detached POSIX group + group signal | OS semantics documented; Node negative-PID path needs prototype | `taskkill /PID ... /T /F`; Job Objects for stronger containment | No pure-Node parity |
| Cancellation | durable cancel event + `AbortController` + platform tree escalation | Feasible | Feasible with `taskkill`/native helper | Abort alone only targets the immediate child |
| Progress heartbeat | timer + atomic heartbeat/snapshot replacement | Equivalent | Equivalent | Evidence of progress, never proof of death |

## 1. Exclusive, sequenced Run Event writes

### What the primitives provide

Node's `'wx'` flag opens a file for writing and fails if the path already
exists. Its flags follow POSIX `O_EXCL` semantics; on Windows, the corresponding
Win32 create disposition is `CREATE_NEW`, which fails when the path exists.[^node-flags][^createfile]
Creating a dedicated lock directory has the same useful namespace property:
one creator succeeds and later creators observe an existing path.[^posix-mkdir][^createdirectory]

Neither primitive embeds owner metadata atomically. A process can die after
creating the file/directory and before writing its PID and token. Ralph must
treat an ownerless lock as an acquisition crash, not immediately assume that
another process may delete it.

### Recommended Run protocol

Use one lock per Run, not one global lock:

1. Queue mutations inside each Node process so only one local mutation attempts
   the cross-process lock at a time.
2. Acquire `runs/<runId>/.write-lock` with `mkdir()` (or a lock file with
   `'wx'`). Write a random, unguessable ownership token plus diagnostic PID,
   process-start identity where obtainable, and acquisition time.
3. While locked, validate the last snapshot and the event tail. Derive
   `nextSeq = lastContiguousSeq + 1`; do not allocate sequence numbers before
   lock acquisition.
4. Serialize exactly one canonical JSON event containing `runId`, `seq`, event
   type, timestamp, ownership/fencing token, and payload. Append it through one
   opened handle, verify the write completed, then call `FileHandle.sync()`
   before exposing a snapshot that includes that sequence.[^node-sync]
5. Replace the snapshot as described in the next section.
6. Before releasing, reread the lock token. Delete the lock only if it is still
   owned by this acquisition.

For a JSONL event file, recovery must accept only complete newline-terminated,
valid records with strictly contiguous sequence numbers. A crash can leave a
partial final record because POSIX `write()` may return after writing fewer
bytes than requested, and neither Node nor Win32 documents a regular-file
record-append boundary.[^posix-write] Quarantine or truncate only that invalid
tail while holding the Run lock; never skip it and continue replay as if a gap
were valid.

An even simpler-to-audit alternative is one immutable event file per sequence,
published from a same-directory temporary file. It avoids shared append
semantics but still needs exclusive final-name publication, metadata durability
testing, and recovery for an abandoned temporary file.

### Why `appendFile()` alone is insufficient

`O_APPEND` makes the offset move to end-of-file as part of each POSIX
`write()`. It does not promise that a logical JSON record is issued as one
write, that all requested bytes are written, or that concurrent Windows writes
have equivalent record boundaries.[^posix-write] `appendFile(..., { flush:
true })` can request a flush before close, but flushing does not create
sequencing or mutual exclusion.[^node-append]

Current Ralph already serializes Copilot session JSONL appends through its
shared state lock in
[`ralph/lib/copilot-session.sh`](../../ralph/lib/copilot-session.sh), and its
tests assert that terminal ledger records are produced in
[`test/copilot-session.test.sh`](../../test/copilot-session.test.sh). A Node
replacement should preserve the lock-before-append invariant and add explicit
sequence/tail validation rather than relying on incidental append behavior.

## 2. Atomic Run Snapshot replacement

The portable shape is:

1. create a uniquely named temporary file in the target snapshot's directory;
2. write the complete snapshot;
3. call `FileHandle.sync()` and close it;
4. rename the temporary file over the target;
5. sync the parent directory/rename metadata where the platform exposes a
   supported mechanism;
6. retain or recover from the previous valid snapshot until the new generation
   is validated.

Keeping the temporary file in the same directory avoids an accidental
cross-volume move. POSIX `rename()` guarantees that, when replacing an existing
non-directory, the destination name remains visible throughout and refers to
either the old file or the new file.[^posix-rename] That is the required macOS
reader-visibility contract, but it is not itself a power-loss guarantee.

On Windows, `MoveFileEx(..., MOVEFILE_REPLACE_EXISTING)` documents replacement.
`MOVEFILE_WRITE_THROUGH` says a copy/delete move is flushed before return, while
Microsoft points to `MoveFileTransacted` for a transacted operation.[^movefileex]
Node's `fs.rename()` documentation promises completion or an error but does not
publish an atomic replacement or write-through contract.[^node-rename] It also
does not expose rename flags.

**Decision:** adopt temp + sync + rename as the snapshot protocol, but call it
"atomic replacement" only after the Windows prototype establishes reader
visibility under the actual Node runtime. Call it "crash durable" only after
fault-injection proves recovery on both NTFS and APFS. On Windows, also test
rename while readers, antivirus, and indexers hold the destination; Win32 share
modes can reject delete/rename access with a sharing violation.[^createfile]

Current Ralph uses same-directory temporary files and `mv` in
[`ralph/lib/state.sh`](../../ralph/lib/state.sh) and
[`ralph/lib/status.sh`](../../ralph/lib/status.sh), with atomic-update coverage
in [`test/status.test.sh`](../../test/status.test.sh). Those tests establish the
repository's intended visibility behavior, not power-loss durability.

## 3. Locks, leases, and stale ownership

Use `mkdir()` or `'wx'` only for **acquisition**. Represent ownership with a
random token and make every cleanup compare that token before deleting. This
prevents a delayed former owner from deleting a successor's lock.

`process.kill(pid, 0)` is useful diagnostic evidence: Node documents signal `0`
as an existence check. It does not identify which process owns that PID, and
Windows may report errors based on permissions.[^node-kill] PID reuse can
therefore make an abandoned lock appear live. A PID check should be combined
with available process-start identity and token evidence, but no portable Node
built-in returns a cross-platform process creation timestamp.

A heartbeat lease improves observability but does not close that gap. A live
owner can stop updating because the machine sleeps, the process is suspended,
the event loop stalls, or storage blocks. A wall-clock expiry is evidence for
manual or guarded recovery, not proof that takeover is safe.

Recommended policy:

- never reap a lock solely because its heartbeat is old;
- fail closed when owner identity is ambiguous;
- allow automatic takeover only when a platform-specific identity check proves
  the recorded process instance is gone and the lock token is unchanged;
- otherwise require an explicit recovery action that records why it fenced the
  old token;
- have every writer revalidate its token immediately before publishing an event
  or snapshot.

Current Ralph's
[`ralph/lib/state.sh`](../../ralph/lib/state.sh) uses `mkdir` locks, PID
liveness/identity checks, and a delay before reaping ownerless locks.
[`extension/lib/platform-shim.mjs`](../../extension/lib/platform-shim.mjs)
uses signal `0` liveness and exclusive `'wx'` PID-file creation.
[`extension/lib/shell-launcher.mjs`](../../extension/lib/shell-launcher.mjs)
already applies the essential token-owned-cleanup rule. The Node design should
retain those conservative properties rather than simplifying stale recovery to
PID or age alone.

## 4. Crash recovery

Crash recovery is an application-level state machine and can be equivalent on
both platforms:

1. Discover Run directories and ignore/quarantine abandoned temp files.
2. Parse and schema-validate the current snapshot. If invalid, fall back to the
   previous validated generation rather than inventing defaults.
3. Read events in order. Verify `runId`, strict sequence continuity, and any
   stored checksum/length. Stop at the first malformed, partial, duplicate, or
   missing event.
4. Rebuild derived Run state by replaying valid events after the snapshot's
   `lastSeq`.
5. Reconcile recorded workers with process identity evidence. Mark ambiguous
   workers `unknown`/`recovery-required`, not failed or dead.
6. Persist a recovery event describing every quarantine, truncation, fence, or
   inferred transition.

Do not depend on asynchronous exit hooks for durability. Node's `'exit'`
listeners may perform only synchronous work, and `'beforeExit'` is not emitted
for explicit termination or uncaught exceptions.[^node-process-exit] Correctness
comes from syncing mutations before acknowledging them and from next-start
replay, not best-effort cleanup during termination.

This matches the repository's fail-closed evidence model in
[`docs/recovery-operations.md`](../recovery-operations.md): durable evidence is
authoritative, and uncertain ownership is surfaced for recovery rather than
silently normalized.

## 5. Subprocess and process-tree supervision

### Immediate child

`child_process.spawn()` is sufficient for an immediate child. Listen for
`'error'` (spawn failure), `'exit'` (process termination), and `'close'` (stdio
closed); consume or redirect stdout/stderr so a full pipe cannot block the
child.[^node-child] A passed `AbortSignal` makes abort behave like
`ChildProcess.kill()` and reports `AbortError`; it does not document descendant
termination.[^node-child]

Keep a live controller process for each active Run. Without a daemon or OS
containment primitive, supervision ends if that controller itself crashes.
Durable Run records permit later reconciliation, but cannot retroactively
contain descendants that escaped.

### macOS

On non-Windows platforms, Node documents that `spawn(..., { detached: true })`
makes the child leader of a new process group and session.[^node-detached]
POSIX `kill()` documents negative PID process-group signaling.[^posix-kill]
However, Node's `process.kill()` documentation does not explicitly promise
negative-PID group semantics. Prototype `process.kill(-child.pid, signal)` on
supported macOS/Node versions before making it a product contract.

Even when that works, containment covers only processes that remain in the
group. A descendant can create another session/process group and escape. The
controller should use graceful group `SIGTERM`, wait a bounded interval, then
group `SIGKILL`, and report survivors/ambiguity.

### Windows

Node documents that Windows does not implement POSIX signals as such; sending
`SIGTERM`, `SIGKILL`, or `SIGINT` performs unconditional termination of the
target process.[^node-kill] Node has no built-in Job Object API.

The dependency-light option already used by Ralph is:

```text
taskkill.exe /PID <pid> /T /F
```

Microsoft documents `/T` as ending the specified process and child processes it
started, and `/F` as forced termination.[^taskkill] This is an OS command, not
a pure Node primitive. It also needs prototype coverage for parent-exits-first,
PID reuse, grandchildren, and races during tree enumeration.

Windows Job Objects are the stronger containment model: Microsoft documents
managing a group of processes as a unit, automatic association of child
processes by default, and whole-job termination.[^job-objects] A job configured
with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` can terminate associated processes
when its last handle closes.[^job-limits] Node built-ins do not expose those
APIs, so this choice requires a small native helper/dependency and careful
handling when Ralph itself is already inside another job.

**Decision:** use `taskkill /T /F` for the first dependency-light implementation
and keep Job Objects as the candidate for strong Windows containment. Do not
claim pure-Node process-tree parity.

Current Ralph implements Windows tree termination and token-owned cleanup in
[`extension/lib/shell-launcher.mjs`](../../extension/lib/shell-launcher.mjs).
[`test/shell-launcher.test.mjs`](../../test/shell-launcher.test.mjs) covers
startup timeout, progress-aware startup, hard startup limits, PID-file
ownership, and descendant termination on Windows. ADR
[`0001-windows-native-single-worker.md`](../adr/0001-windows-native-single-worker.md)
records why controller-owned tree termination replaces Bash signal cleanup on
native Windows.

## 6. Cancellation

Cancellation needs two layers:

1. **Durable intent:** under the Run lock, append a `cancel-requested` event
   with actor, reason, and sequence. Recovery must continue cancellation if the
   controller crashes after recording intent.
2. **Runtime enforcement:** abort pending Node operations with one composed
   `AbortSignal`, stop scheduling new work, request graceful child termination,
   then escalate to the platform tree-kill strategy after a deadline.

`AbortController` is a coordination mechanism, not containment. Node documents
that aborting a spawned child is similar to calling `.kill()` on that child.[^node-abort][^node-child]
Completion should be another durable event only after the child/tree exit has
been observed or after Ralph records an explicit `cancellation-uncertain`
outcome. A restart reconciles any Run with requested-but-not-completed
cancellation.

## 7. Progress heartbeats

Use polling, not filesystem notifications, as the correctness path:

- update a small heartbeat snapshot with the atomic-replacement protocol, or
  append coarse-grained `progress` events;
- include Run/worker identity token, monotonic progress counter, phase, and wall
  time;
- let observers poll with bounded jitter;
- use `fs.watch()` only as a wake-up optimization because Node states that it
  is not fully consistent across platforms.[^node-watch]

Heartbeats prove that progress was observed at a point in time. Their absence
does not prove process death. Report separate states such as `progressing`,
`stalled`, `identity-dead`, and `unknown`; only verified process identity or
observed child exit can support the stronger state.

Ralph's existing launcher polls startup progress and applies both a stall
timeout and a hard upper bound in
[`extension/lib/shell-launcher.mjs`](../../extension/lib/shell-launcher.mjs).
The corresponding tests in
[`test/shell-launcher.test.mjs`](../../test/shell-launcher.test.mjs) are the
behavioral baseline for a Node-native Run heartbeat.

## Prototype gates

These experiments are required before implementation claims equivalence:

1. **Event fault injection:** two Node writers on NTFS and APFS; kill a writer
   during every write/sync boundary; verify exclusive sequence allocation,
   partial-tail detection, recovery, and no acknowledged event loss.
2. **Snapshot reader visibility:** continuously parse the target while another
   process performs same-directory temp + sync + rename. Exercise NTFS with
   open readers, antivirus/indexer activity, and retryable sharing violations.
3. **Power-loss recovery:** crash or power-cut VMs after file sync, after
   rename, and after attempted parent metadata sync. Verify which of old/new
   snapshot and event generations survive on target NTFS and APFS versions.
4. **Lock acquisition crashes:** terminate before and after owner metadata,
   during heartbeat replacement, and during token-checked unlock. Include PID
   reuse, suspended owners, sleep/wake, and delayed former-owner cleanup.
5. **macOS group termination:** on every supported Node/macOS version, verify
   negative-PID `process.kill`, graceful escalation, grandchildren, and an
   intentionally escaped session.
6. **Windows tree termination:** verify `taskkill /T /F` when the root is alive,
   when it exits before cancellation, while descendants spawn, and after PID
   reuse. Compare against a Job Object helper.
7. **Controller crash:** kill the Node controller while work continues. Verify
   the documented product outcome: later reconciliation for the built-in/
   `taskkill` design, or automatic containment if a Job Object helper is chosen.

Until these pass, the unsupported properties should remain named capability
gaps in the design and tests, not hidden behind retries or optimistic wording.

## Recommended implementation boundary

Keep the implementation dependency-light by separating:

- a **portable Node Run store**: per-Run queue, cross-process token lock,
  sequenced events, snapshot publication, replay, cancellation intent, and
  heartbeat records;
- a **platform supervisor adapter**:
  - macOS: detached process group plus tested group signaling;
  - Windows baseline: `taskkill.exe /T /F`;
  - Windows strong mode: optional narrow Job Object helper.

The portable store can be made deterministic and testable without Bash, a
daemon, or a database. The supervisor adapter and filesystem fault suite are
where platform-specific evidence belongs.

## Primary sources

[^node-fs]: Node.js, [`node:fs` promises API](https://nodejs.org/api/fs.html#promises-api): concurrent modifications are not synchronized or threadsafe.
[^node-flags]: Node.js, [file system flags](https://nodejs.org/api/fs.html#file-system-flags), including exclusive `'x'` behavior.
[^node-append]: Node.js, [`fs.appendFile()`](https://nodejs.org/api/fs.html#fsappendfilepath-data-options-callback), including the `flush` option.
[^node-sync]: Node.js, [`FileHandle.sync()`](https://nodejs.org/api/fs.html#filehandlesync).
[^node-rename]: Node.js, [`fs.rename()`](https://nodejs.org/api/fs.html#fsrenameoldpath-newpath-callback).
[^node-watch]: Node.js, [`fs.watch()` caveats](https://nodejs.org/api/fs.html#caveats).
[^node-child]: Node.js, [`child_process.spawn()`](https://nodejs.org/api/child_process.html#child_processspawncommand-args-options) and child-process event/pipe behavior.
[^node-detached]: Node.js, [`options.detached`](https://nodejs.org/api/child_process.html#optionsdetached).
[^node-kill]: Node.js, [`process.kill()`](https://nodejs.org/api/process.html#processkillpid-signal).
[^node-abort]: Node.js, [`AbortController` and `AbortSignal`](https://nodejs.org/api/globals.html#class-abortcontroller).
[^node-process-exit]: Node.js, [process `'exit'` and `'beforeExit'` events](https://nodejs.org/api/process.html#event-exit).
[^posix-write]: The Open Group, POSIX.1-2024, [`write()`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/write.html).
[^posix-rename]: The Open Group, POSIX.1-2024, [`rename()`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
[^posix-fsync]: The Open Group, POSIX.1-2024, [`fsync()`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/fsync.html).
[^posix-mkdir]: The Open Group, POSIX.1-2024, [`mkdir()`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/mkdir.html).
[^posix-kill]: The Open Group, POSIX.1-2024, [`kill()`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/kill.html).
[^createfile]: Microsoft, [`CreateFileW`](https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-createfilew), including `CREATE_NEW` and share modes.
[^createdirectory]: Microsoft, [`CreateDirectoryW`](https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-createdirectoryw).
[^movefileex]: Microsoft, [`MoveFileExW`](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw), including replacement, write-through, and the distinct transacted API.
[^taskkill]: Microsoft, [`taskkill`](https://learn.microsoft.com/windows-server/administration/windows-commands/taskkill), including `/T` and `/F`.
[^job-objects]: Microsoft, [Job Objects](https://learn.microsoft.com/windows/win32/procthread/job-objects).
[^job-limits]: Microsoft, [`JOBOBJECT_BASIC_LIMIT_INFORMATION`](https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-jobobject_basic_limit_information), including `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
