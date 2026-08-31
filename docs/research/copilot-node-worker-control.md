# Native Copilot CLI worker control from Node

Research for [#255](https://github.com/tjegbejimba/ralph-loop-dashboard/issues/255), completed 2026-08-31.

## Answer

Ralph can replace its Bash-level `copilot -p` invocation with the official
[`@github/copilot-sdk`](https://github.com/github/copilot-sdk/tree/main/nodejs)
Node package. The supported local entry point is a `CopilotClient` using the
default stdio runtime, followed by `createSession()` or `resumeSession()`,
`sendAndWait()`, and explicit shutdown. The SDK gives Node native control over
session identity, events, permissions, user-input requests, abort, resume, and
runtime lifecycle.

The SDK is not a complete worker supervisor. Its documented shutdown methods
act on the runtime process it owns, but neither the public contract nor the
source promises descendant-process-tree termination, operating-system job
objects, process groups, durable application locks, exact crash-recovery
proofs, or repository-level success. Ralph must continue to own those concerns.

The recommended design is therefore:

1. Run each Copilot session in a dedicated Node worker-host process.
2. Give every attempt an application-generated UUID and persist it before
   sending the first prompt.
3. Use the SDK's stdio transport inside the worker host.
4. Keep Ralph's controller-side run ledger, worktree proof, single-owner lock,
   platform-specific tree termination, and GitHub outcome verification.
5. Recover only by the exact recorded session ID after revalidating the same
   run, issue, worker, worktree, branch, base commit, dead process, and persisted
   session.

This boundary provides one cross-platform Copilot integration while retaining
the safeguards that are outside the SDK's contract.

## Scope and evidence labels

This report uses only primary sources:

- **Documented** means the official Copilot SDK documentation, official GitHub
  Copilot CLI documentation, or the SDK's public type declarations explicitly
  defines the behavior.
- **Observed** means the behavior is present in the current official SDK source,
  the installed Copilot CLI on the research machine, or Ralph's source/tests at
  commit
  [`961ef0f`](https://github.com/tjegbejimba/ralph-loop-dashboard/tree/961ef0ff2baf91492755601c12741975948e9e70).
  It is useful evidence but not necessarily a compatibility promise.
- **Unknown** means no reviewed primary source establishes the behavior.

The installed Windows CLI reported `GitHub Copilot CLI 1.0.82-2`. Its package
metadata reported `@github/copilot` 1.0.2 and exposed an `./sdk` export. That
installed export is an implementation observation, not the documented package
name. New Node integration should depend on the public
`@github/copilot-sdk` package described by the official
[Node SDK README](https://github.com/github/copilot-sdk/blob/main/nodejs/README.md).

## Supported native Node invocation

### SDK path

The documented Node API is:

```js
import { CopilotClient } from "@github/copilot-sdk";

const client = new CopilotClient();
await client.start();

const session = await client.createSession({
  sessionId,
  workingDirectory,
  onPermissionRequest,
});

const finalMessage = await session.sendAndWait({ prompt });
await session.disconnect();
await client.stop();
```

`new CopilotClient()` uses a locally spawned stdio runtime by default. The
public transport API also exposes stdio, TCP, URI, and an experimental
in-process connection. The supported transport choices and their ownership
semantics are defined in the
[Node README](https://github.com/github/copilot-sdk/blob/main/nodejs/README.md)
and
[`RuntimeConnection`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/types.ts).

For Ralph, stdio is the right initial transport:

- it does not require a separately provisioned server or port;
- the SDK owns the runtime it starts;
- the worker host can treat transport loss as worker failure; and
- each worker can be isolated in its own OS process.

TCP or URI transport changes process ownership: the application connects to an
already-running runtime, so `client.stop()` cannot be assumed to terminate that
external server. The in-process transport is explicitly experimental and is
not an appropriate reliability boundary for the first migration.

### CLI subprocess path

Spawning `copilot -p` from Node remains a documented automation path.
GitHub's
[programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference)
states that programmatic mode accepts one prompt, performs the work, prints the
response, and exits. The
[command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
documents flags including session selection, permissions, model selection, and
JSON output. The installed CLI additionally confirmed `--session-id`,
`--resume`, `--continue`, `--name`, `--no-ask-user`, `--no-remote`, and
`--allow-all`.

That subprocess interface is supported, but it exposes less structured control
than the SDK: events, permission requests, user-input requests, and lifecycle
state must be inferred from process I/O and exit. Ralph currently follows this
path through Bash rather than invoking the CLI directly from Node
([`ralph.sh` lines 1219-1248](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/ralph.sh#L1219-L1248)).

## Process supervision

### What the SDK owns

**Documented:** `client.stop()` is graceful client shutdown and
`client.forceStop()` is the fallback when graceful shutdown cannot complete.
`session.disconnect()` releases the live session connection without deleting
the persisted session. These methods are exposed by the
[client](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts)
and
[session](https://github.com/github/copilot-sdk/blob/main/nodejs/src/session.ts)
implementations and described in the
[Node README](https://github.com/github/copilot-sdk/blob/main/nodejs/README.md).

**Observed in official source:** for an SDK-spawned runtime, `stop()` requests
runtime shutdown, disposes transport state, and calls `ChildProcess.kill()` on
the owned process. `forceStop()` calls `kill("SIGKILL")` on that process. These
are process-level actions in
[`client.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts);
the source does not create a Windows Job Object, establish a POSIX process
group, or walk descendants.

**Unknown:** whether tools started by the runtime are always terminated by
`stop()`, `forceStop()`, transport loss, or `session.abort()` on either Windows
or macOS. No reviewed SDK contract promises child-tree cleanup. Ralph must not
interpret "runtime process exited" as "every command started during the turn is
dead."

### Ralph's required ownership boundary

Use a dedicated Node worker host per Copilot session, even though one
`CopilotClient` can manage multiple sessions. This creates a PID the controller
can monitor and terminate without taking down unrelated workers. A worker host
should:

1. start one client and one session;
2. emit a registered message only after the client and session are ready;
3. journal the session ID and lifecycle transitions;
4. translate SDK events into structured worker events;
5. on cancellation, call `session.abort()`, wait a bounded grace period, then
   disconnect and stop the client; and
6. remain killable as a complete platform process tree if graceful shutdown
   fails.

The controller, not the SDK session, should own the timeout. A timeout is a
controller decision because it may need to terminate commands that outlive the
runtime.

## Session identity and resume

### Stable identity

**Documented:** `createSession()` accepts `sessionId`; `resumeSession(sessionId)`
resumes that exact persisted session. `session.id` exposes the active identity.
The SDK also provides session listing and deletion. See the
[Node README](https://github.com/github/copilot-sdk/blob/main/nodejs/README.md),
[`client.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts),
and
[session-persistence documentation](https://github.com/github/copilot-sdk/blob/main/docs/features/session-persistence.md).

**Observed in official source:** local session creation generates an ID when the
caller omits one. The persistence guide nevertheless instructs applications
that need later resume to provide and retain their own ID. Ralph should follow
the documented workflow rather than rely on generated-ID behavior.

Use the application-generated session ID as the authoritative key. Persist a
record before the first prompt containing at least:

```text
runId, issueNumber, workerId, sessionId, sessionName,
canonicalWorktree, branch, baseCommit, startedAt, workerHostPid
```

A human-readable name is useful for diagnostics but is not identity.

### Persistence boundary

**Documented:** local sessions are stored under
`~/.copilot/session-state/{sessionId}/`. Persisted state includes conversation
history, tool results, planning state, and artifacts. Provider API keys and
in-memory custom tool state are not persisted. `disconnect()` preserves the
session; `deleteSession()` removes it. The SDK does not provide a built-in
single-owner lock, and concurrent access to the same session is undefined
([session persistence](https://github.com/github/copilot-sdk/blob/main/docs/features/session-persistence.md)).

Ralph therefore needs an application lock keyed by session ID. Recovery must
fail closed if another worker host or controller can still own the session.

### CLI identity

The equivalent exact CLI operations are:

- fresh: `--session-id <uuid>`;
- exact resume: `--resume=<full-session-id>`;
- diagnostic name: `--name <name>`; and
- local-only creation: `--no-remote`.

`--continue` selects the most recent session and is unsafe for worker recovery
because "most recent" is not a stable run/issue/worker identity. Ralph already
uses exact IDs for recovery and creates UUIDv4 identities for fresh sessions
([`ralph.sh` lines 1219-1237](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/ralph.sh#L1219-L1237);
[`copilot-session.sh` lines 20-47](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/lib/copilot-session.sh#L20-L47)).

Ralph's ordinary soft resume is different: it starts a new Copilot session and
injects `RALPH_RESUME` instructions pointing at an existing branch
([`ralph.sh` lines 1181-1207](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/ralph.sh#L1181-L1207)).
Only the explicit recovery path uses `--resume=<recorded-session-id>`.

## Permissions and approval

### SDK permission requests

**Documented:** a session may supply `onPermissionRequest`. The application can
approve, deny, or otherwise resolve each request. Omitting the handler surfaces
permission events but leaves requests pending for external/manual resolution.
The SDK exports an `approveAll` helper, but it is valid only when organization
or user policy permits blanket approval. See the permission examples in the
[Node README](https://github.com/github/copilot-sdk/blob/main/nodejs/README.md)
and the callback contract in
[`types.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/types.ts).

An unattended Ralph worker must never depend on a human resolving a pending
request. It needs a deterministic policy callback. Prefer an explicit,
least-privilege allowlist for the worker worktree and required network/tool
operations. If Ralph intentionally preserves its present trust model,
`approveAll` is the SDK equivalent of the broad CLI posture, subject to managed
settings.

**Observed:** current Ralph passes `--allow-all`, allowing tools, paths, and
URLs without prompts
([`ralph.sh` lines 1240-1247](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/ralph.sh#L1240-L1247)).

### User-input requests

**Documented:** supplying `onUserInputRequest` enables the SDK's `ask_user`
flow. The handler must return a response. For an unattended worker, either
register a deterministic broker with a bounded timeout or omit the handler so
the tool is not enabled. The callback is defined in
[`types.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/types.ts).

**Observed in official source:** if a user-input request reaches a session with
no registered handler, the SDK throws `User input requested but no handler
registered`
([`session.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/session.ts)).
The CLI counterpart is `--no-ask-user`, confirmed by installed help.

Ralph should default unattended workers to no interactive input and treat an
unexpected input request as a failed turn, not as a wait with no owner.

## Cancellation

Use distinct cancellation levels:

| Level | Action | Meaning |
| --- | --- | --- |
| Turn | `session.abort()` | Abort the current processing turn; keep the session reusable. |
| Session connection | `session.disconnect()` | Release the live session while preserving persisted data. |
| Runtime | `client.stop()` | Gracefully stop an SDK-owned runtime. |
| Runtime fallback | `client.forceStop()` | Force the SDK-owned runtime process to exit. |
| Worker tree | Controller platform kill | Terminate the dedicated worker host and all descendants. |

The first four levels are SDK operations
([`session.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/session.ts);
[`client.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts)).
The last is an application responsibility.

Cancellation does not prove rollback. A tool may have committed, pushed,
created a PR, or changed an issue before cancellation. Ralph must inspect the
worktree and remote state before deciding whether to resume, retry, or mark the
attempt failed. No reviewed source defines exactly-once tool execution across
abort, runtime crash, or session resume.

## Exact-session recovery

The SDK supplies the mechanism (`resumeSession(sessionId)`), but Ralph must
supply the proof that the requested session is the right and only recoverable
worker.

Current Ralph's controller validates:

- canonical registered worktree and expected branch;
- a dirty worktree, showing there is preserved work to recover;
- base commit ancestry;
- run queue, status, immutable ownership, and claim state;
- exactly one matching session start event and no terminal event;
- dead launcher and worker PIDs;
- persisted session identity and worktree;
- no live session lock;
- an open Ralph-owned slice issue; and
- no open PR already associated with the worker branch.

That controller proof is implemented in
[`shell-launcher.mjs` lines 110-183](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/extension/lib/shell-launcher.mjs#L110-L183)
and is revalidated immediately before spawn
([lines 590-614](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/extension/lib/shell-launcher.mjs#L590-L614)).
Bash independently revalidates the handoff before invoking Copilot. Tests prove
that proof drift stops before Copilot is called and that only the registered
session ID is resumed
([`copilot-session.test.sh` lines 405-478](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/test/copilot-session.test.sh#L405-L478)).

Retain these checks when moving to the SDK. Replace CLI-file probing only where
the SDK provides a public query. In particular, Ralph currently reads
`workspace.yaml` and `inuse.<pid>.lock`
([`copilot-session.sh` lines 124-205](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/lib/copilot-session.sh#L124-L205)).
Those filenames are observed CLI storage details, not documented SDK contracts.
The durable design should use a Ralph-owned session ledger and lock as its
authority; CLI storage should be only corroborating evidence.

**Unknown:** the exact crash-consistency point of persisted turns and whether a
resumed session can distinguish a tool operation that completed externally but
whose result was not durably recorded. Exact session identity does not imply
exactly-once side effects. Recovery should preserve the worktree, inspect
Git/GitHub state, and prompt the agent to reconcile before repeating actions.

## Completion behavior

**Documented:** `sendAndWait()` waits until the session becomes idle and returns
the final assistant message when one exists. `session.idle` is also available
for waiting on processing to stop
([`session.ts`](https://github.com/github/copilot-sdk/blob/main/nodejs/src/session.ts);
[Node README](https://github.com/github/copilot-sdk/blob/main/nodejs/README.md)).
The SDK's
[lifecycle hooks](https://github.com/github/copilot-sdk/blob/main/docs/hooks/hooks-overview.md)
can observe and influence agent lifecycle, but they do not know Ralph's external
definition of success.

Idle means the turn ended. It does not mean:

- the issue is closed;
- a PR exists or merged;
- required checks passed;
- the repository is clean;
- no child process remains; or
- the requested task was accomplished.

Ralph already makes this distinction. A nonzero CLI exit is a worker failure
([`ralph.sh` lines 1267-1281](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/ralph.sh#L1267-L1281)),
but exit zero is followed by worktree-isolation checks and GitHub verification.
The completion verifier requires issue closure with merged-PR evidence and
handles GitHub eventual consistency
([`ralph.sh` lines 1251-1305](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/ralph.sh#L1251-L1305)).
When no qualifying merge exists, Ralph may make bounded soft-resume attempts
only when durable branch evidence exists
([`ralph.sh` lines 1475-1543](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/ralph.sh#L1475-L1543)).

An SDK migration should map `sendAndWait()` completion to "agent idle," then run
the same repository-level verifier. The final assistant message is diagnostic
evidence, not the success predicate.

**Unknown:** the CLI's complete exit-code taxonomy for authentication, network,
model, policy, agent, and signal failures. The reviewed command documentation
does not define stable meanings beyond success/failure. Do not build retry
policy around undocumented numeric codes.

## Windows and macOS

### Windows

**Observed in Ralph:** the current native-Windows launch path is single-worker
because detached Git Bash/Cygwin fork emulation fails. Node resolves Git Bash
explicitly, launches `launch.sh --foreground`, and refuses a bare `bash`
fallback that could silently enter WSL with different tools and credentials
([ADR 0001](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/docs/adr/0001-windows-native-single-worker.md);
[ADR 0002](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/docs/adr/0002-no-path-bash-fallback.md)).

Node `SIGTERM` does not provide Ralph a reliable trappable Git Bash shutdown.
Ralph therefore calls `taskkill.exe /PID <pid> /T /F`, waits for the tree to
exit, and removes only setup locks carrying the launch token
([`shell-launcher.mjs` lines 216-249](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/extension/lib/shell-launcher.mjs#L216-L249)).

A direct SDK worker host removes Git Bash from the Copilot invocation path, so
the specific Cygwin single-worker limitation no longer applies to that layer.
It does not by itself prove native-Windows parallel workers are safe; worktree,
controller, credential, resource, and process-tree behavior still require
tests. Keep full-tree termination for the dedicated Node worker-host PID.

### macOS

**Observed in Ralph:** the launcher discovers worker descendants using `ps` and
PPID propagation
([`process-scope.mjs`](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/extension/lib/process-scope.mjs)).
Startup failure sends `SIGTERM` to the launcher. `launch.sh` uses
`caffeinate -i -m -w <worker-pid> -t 21600` to prevent idle and disk sleep while
the worker is alive
([`launch.sh` lines 330-369](https://github.com/tjegbejimba/ralph-loop-dashboard/blob/961ef0ff2baf91492755601c12741975948e9e70/ralph/launch.sh#L330-L369)).

Keep sleep inhibition around the dedicated Node worker host. Do not rely on
`client.forceStop()` to kill descendants; the SDK source does not establish a
macOS process-group contract. If Ralph adopts process-group termination, it
should be introduced and tested as a Ralph supervisor feature rather than
attributed to Copilot.

## Guarantee matrix

| Concern | Documented guarantee | Observed behavior | Unknown / Ralph responsibility |
| --- | --- | --- | --- |
| Native Node API | `@github/copilot-sdk`, `CopilotClient`, sessions, stdio/TCP/URI transports | Installed `@github/copilot` also exposes `./sdk` | Compatibility of the installed internal export; use the public package |
| Invocation | SDK `send`/`sendAndWait`; CLI `copilot -p` | Ralph shells through `launch.sh` and `ralph.sh` | Detailed CLI exit-code taxonomy |
| Session identity | Caller may set `sessionId`; exact `resumeSession(id)` | CLI accepts `--session-id` and exact `--resume` | Generated-ID recovery as a contractual workflow |
| Persistence | Local state under `~/.copilot/session-state/{id}`; disconnect preserves; delete removes | Ralph inspects `workspace.yaml` and lock filenames | File layout stability, pruning policy, crash-consistency point |
| Permissions | `onPermissionRequest`; policy controls blanket approval | Ralph uses `--allow-all` | Best least-privilege policy for Ralph |
| User input | `onUserInputRequest` enables `ask_user` | No handler throws if a request arrives; CLI has `--no-ask-user` | A safe unattended escalation broker |
| Turn cancel | `session.abort()` aborts current processing | Session remains reusable in SDK design | External tool side effects and descendant cleanup |
| Runtime stop | `stop()` and `forceStop()` stop an SDK-owned runtime | Source kills the owned child process | Descendant-tree termination on Windows/macOS |
| Recovery | Exact session ID can be resumed | Ralph proves ownership and tests fail-closed drift | Exactly-once side effects after crash |
| Completion | `sendAndWait()` / `idle` signal processing stopped | Ralph verifies merged-PR issue closure separately | Stable CLI failure categories; domain success remains application-defined |

## Recommendation for Ralph

Adopt the SDK behind a worker-host protocol, not directly inside the dashboard
controller:

```text
dashboard controller
  -> dedicated Node worker host
       -> CopilotClient (stdio runtime)
            -> exact Copilot session
```

The worker protocol should have explicit `registered`, `event`, `idle`,
`failed`, and `stopped` messages. The controller should persist the exact
session identity before `sendAndWait()`, retain the current run/worktree proof,
and run the existing GitHub completion verifier after idle. Cancellation should
be graceful first and platform tree-kill last. Exact recovery should call
`resumeSession(recordedSessionId)` only after the existing proof passes.

Do not base production behavior on `workspace.yaml`, `inuse.*.lock`, session
names, `--continue`, final assistant prose, or undocumented CLI exit codes.
Treat them as diagnostics at most. Before replacing the current launcher, add
platform integration tests that deliberately leave a long-running tool child,
kill the worker host, resume a persisted session, and verify on both Windows
and macOS that:

- no process survives cancellation;
- only the recorded session is resumed;
- concurrent resume fails closed;
- external side effects are reconciled rather than blindly repeated; and
- idle is not reported as success until the repository outcome verifier passes.

That is the narrowest design supported by the primary sources and consistent
with Ralph's existing safety model.
