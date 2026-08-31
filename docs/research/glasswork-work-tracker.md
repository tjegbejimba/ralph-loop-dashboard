# Glasswork as a Ralph work tracker

Research note for [issue #254](https://github.com/tjegbejimba/ralph-loop-dashboard/issues/254).
It asks what interface a native Node Ralph engine can use to load, claim, update,
complete, and attach delivery evidence to Glasswork Tickets without depending on
an agent-only tool.

All Glasswork citations are pinned to commit
[`508634c48c090d8f35031c410f3cc368c78244b6`](https://github.com/tjegbejimba/Glasswork/tree/508634c48c090d8f35031c410f3cc368c78244b6)
from 2026-08-30.

## Verdict

**Use `glasswork-mcp` over stdio, but treat its tool contract as
version-pinned rather than unconditionally stable.** MCP is a wire protocol, not
an agent-only affordance: a Node process can spawn the executable and use an MCP
client directly, with no LLM in the loop. It is the only supported programmatic
surface for Task mutation. There is no Task CLI, HTTP API, daemon, or socket
transport. The project is still `0.x`, its changelog records breaking minor
releases, and its first-party README has drifted from the implemented tools.
Ralph must therefore pin the exact `version+commit`, perform the capability
handshake at startup, and fail closed on contract drift.

Load/list, update, complete, and evidence attachment all have supported MCP
operations with fail-closed revision checks. **Claiming is the hard gap.**
Glasswork has no assignee, owner, claim, lease, heartbeat, expiry, reclaim, or
fencing-token model. A compare-and-swap transition from `todo` to `doing` can
ensure that only one cooperating worker wins a race, but Glasswork cannot record
who won or determine whether that worker is still alive. Ralph must own those
semantics.

## 1. Supported interface

### 1.1 MCP over stdio

`glasswork-mcp` is a .NET 10 console application. Its startup registers the MCP
stdio transport and the Glasswork tool classes; its only conventional CLI
argument is `--version`. Logging is deliberately sent to stderr because stdout
is reserved for MCP. See
[`Program.cs`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Program.cs)
and the governing
[`ADR 0007`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/docs/adr/0007-mcp-server.md).

The ADR explicitly sets these boundaries:

- stdio only; no HTTP, TCP, named-pipe, or other network listener;
- no authentication, because any client able to spawn the local binary already
  has access to the vault;
- the configured vault is the only writable surface;
- stateless reads that re-read the vault on every call.

Consequently, a native Node engine can use a standard MCP client library, or
implement the MCP JSON-RPC framing itself. It must parse the JSON string returned
inside each MCP text result: the tools serialize their output records to strings
rather than returning an independently published typed output schema. The
records are defined in
[`GlassworkTools.cs` lines 3203-3400](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L3203-L3400).

### 1.2 Discovery and compatibility handshake

Vault discovery checks `GLASSWORK_VAULT` first, then the app's persisted
`%LocalAppData%\Glasswork\ui-state.json`. The value is the vault root, and
`<vault>/wiki/todo` must already exist. Discovery failure does not terminate the
server; it filters vault-dependent tools out of `tools/list`. Process startup is
therefore not a readiness check. See
[`VaultDiscovery.cs`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/VaultDiscovery.cs)
and the
[`MCP README`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/README.md).

The installer publishes the active executable path in
`%LocalAppData%\Glasswork\Mcp\current.json`; `glasswork-mcp --version` returns
`<package-version>+<repository-commit>`. At the researched commit, the package is
version 0.11.1 and references `ModelContextProtocol` 1.2.0
([project file](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Glasswork.Mcp.csproj),
[build identity](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/McpBuildIdentity.cs)).

`get_capabilities` returns `contract_version: "1.0"` and the required capability
set, including `resource_revisions`, `typed_transactions`,
`transaction_idempotency`, and `recoverable_all_or_none_commit`. The first-party
contract says clients must fail before reading or mutating if the complete set is
not advertised; there is no downgrade negotiation
([`CapabilityTools.cs` lines 11-31](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/CapabilityTools.cs#L11-L31)).

The changelog records breaking tool-contract changes in minor `0.x` releases,
including the fail-closed mutation contract in 0.9.0
([`CHANGELOG.md`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/CHANGELOG.md)).
The README also omits implemented tools and understates accepted statuses.
Ralph should treat the executable identity, capabilities, and actual
`tools/list` response as one startup gate.

### 1.3 Vault files are readable, but not a safe mutation API

Tasks are Markdown files at `<vault>/wiki/todo/<task-id>.md` with YAML
frontmatter. `FrontmatterParser` owns the schema and body sections
([source](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/FrontmatterParser.cs));
`VaultService.GetFilePath` maps a safe Task id to its file while enforcing vault
containment
([lines 1053-1067](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/VaultService.cs#L1053-L1067)).

A Node engine can safely inspect those files, but direct Task writes bypass
Glasswork's revision checks, idempotency store, journal, named mutex, atomic
replacement, and self-write markers. ADR 0007 explicitly leaves linearizable
compare-and-swap against arbitrary unmanaged writers out of scope. Direct Task
mutation is therefore not a supported integration contract.

## 2. Identity and revision model

### 2.1 Task identity

The canonical Task id is the Markdown filename stem and is also stored in
frontmatter. The safe alphabet is lowercase ASCII alphanumerics and hyphens.
Incoming MCP ids are sanitized by lowercasing and *removing* other characters,
not rejected
([`SanitizeId`, lines 3196-3201](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L3196-L3201)).
That permits aliases: `Ralph #254` and `ralph254` resolve to the same id.

Ralph should generate and locally validate deterministic ids matching
`^[a-z0-9-]+$`; it should never depend on server-side coercion. Creation should
use an explicit id, `if_absent: true`, and a deterministic `mutation_id`.
`add_task` does not add the collision suffix used by the desktop app and returns
`conflict` when the generated file already exists
([tool path, lines 211-329](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L211-L329),
[`CreateTask`, lines 1379-1490](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/ResourceMutationService.cs#L1379-L1490)).

### 2.2 Resource Revision

A Resource Revision is an opaque token derived from the exact bytes returned by
a managed read. Clients compare it for equality only
([`UBIQUITOUS_LANGUAGE.md`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/UBIQUITOUS_LANGUAGE.md)).
The current implementation is `rr1-` plus a SHA-256 digest of the whole file
([lines 1796-1797](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/ResourceMutationService.cs#L1796-L1797)).
Managed reads populate the revision from the bytes they parsed
([`VaultService.Load`, lines 169-181](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/VaultService.cs#L169-L181)).

Operational consequences:

- it is per resource, opaque, non-monotonic, and not an event sequence;
- any byte change, including cosmetic reformatting, invalidates a held revision;
- identical bytes reproduce an earlier token, so ABA is possible;
- it cannot serve as a lease epoch or fencing token;
- Task reads and artifact reads expose their relevant revisions.

## 3. Concurrency and durability

### 3.1 Fail-closed optimistic concurrency

Every public Task or Task-owned-file mutation requires a client-generated
`mutation_id` and an applicable precondition: `if_absent: true` for creation or
`if_revision` for update. Missing preconditions return
`precondition_required` without side effects. The guards are visible on
`add_task`, `add_artifact`, `cancel_task`, `restore_task`, `delete_task`, and
`update_task`
([`GlassworkTools.cs`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs)).

`ResourceMutationService.MutateConditional` implements the commit boundary
([lines 655-806](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/ResourceMutationService.cs#L655-L806)):

1. Replay a previously recorded identical request; reject a reused
   `mutation_id` with a different request hash as `mutation_id_reused`.
2. Read current bytes and compare `if_revision`.
3. Apply and validate the proposed domain changes.
4. Re-read immediately before commit and return `conflict` if bytes changed.
5. Return `no_op` without rewriting when the serialized state is semantically
   unchanged.
6. Journal original and updated bytes, re-check, atomically replace, mark the
   journal committed, and record the idempotent outcome.

Conflict responses include the current revision and snapshot, allowing Ralph to
re-evaluate without an extra read. Multi-Task transactions perform equivalent
per-Task checks and use a graph journal
([lines 808-1070](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/ResourceMutationService.cs#L808-L1070)).

Recorded mutation outcomes are retained for 30 days in
`<vault>/wiki/todo/.glasswork/resource-mutations.json`; recovery uses
`mutation-journal.json`
([state and journal code, lines 1838-1892](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/ResourceMutationService.cs#L1838-L1892)).
Ralph should derive `mutation_id` deterministically from a run, Task, and logical
step, retry the exact request after a crash, and never reuse an id for changed
input.

### 3.2 Managed locking does not protect foreign file writers

`VaultScopedCoordinator` combines an in-process reader/writer lock with a named
Windows mutex `Local\GlassworkVault-<vault-path-sha>`
([source](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/VaultScopedCoordinator.cs)).
The `Local\` namespace is scoped to a Windows terminal-services session. The
mutex coordinates the desktop app and MCP only when they use the managed
boundary; it cannot constrain Obsidian, an editor, a service in another session,
or a Node process writing files itself.

`SelfWriteCoordinator` additionally publishes short-lived
`.glasswork/recent-writes.json` markers so the app does not misclassify managed
writes as external changes
([source](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/SelfWriteCoordinator.cs)).
This is another reason not to build Ralph on direct Task-file mutation.

## 4. Lifecycle and claiming

Glasswork's internal statuses are `todo`, `in-progress`, `blocked`, `done`, and
`cancelled`; MCP maps `in-progress` to external status `doing`
([`GlassworkTask.Statuses`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Models/GlassworkTask.cs#L118-L125),
[`MapToExternalStatus`, lines 3168-3182](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L3168-L3182)).

Core enforces the transition rules in
[`TaskService.cs`](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/TaskService.cs):

- setting `done` stamps `completed_at`; moving away clears it;
- `blocked` requires the dedicated blocked operation and a reason;
- cancelling is reversible and clears `my_day`;
- cancelled Tasks cannot otherwise be mutated until restored;
- hard deletion has additional preflight, title, cascade, and revision guards and
  should not be part of Ralph's normal lifecycle.

The mutation field allowlist contains status, tags, relationships, links,
description, notes, and scheduling fields, but no assignee, owner, worker,
claim, or lease field. Unknown fields return a validation error
([field switch, lines 1528-1593](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Core/Services/ResourceMutationService.cs#L1528-L1593)).

The only supported claim approximation is:

1. `query_tasks` for eligible `todo` Tasks and retain each
   `resource_revision`.
2. Call `transact_tasks` with one `set_task_fields` operation setting status to
   `doing`, guarded by that revision and a deterministic `mutation_id`.
3. Interpret `applied` as winning the race, `conflict` as losing it, and
   `no_op` as an exact replay or semantically unchanged result.

This closes the selection/update race for cooperating clients, but it provides
no owner identity, TTL, heartbeat, expiry, stale-claim recovery, or fencing
token. A crashed worker leaves the Task in `doing` indefinitely. Tags can carry
an advisory worker id, but setting tags replaces the complete set and does not
create enforceable lease semantics. Unknown frontmatter keys happen to
round-trip, but MCP cannot set them and no first-party contract defines them as
an extension point; using them for ownership would be unsafe.

## 5. Loading and updating work

`query_tasks` is the best queue primitive
([lines 406-514](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L406-L514)).
It supports typed filters for parent, statuses, type, tags, dependency state,
ordering, a limit from 1 to 100, and opaque cursor pagination. Results include
the Task revision and a `read_basis`: the related Task snapshots and revisions
that affected a relation-aware match. `blocked_by` is a dependency relation,
distinct from the Task's `blocked` lifecycle status
([domain definitions](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/UBIQUITOUS_LANGUAGE.md)).

`get_task` re-reads a Task and its artifact directory. `load_context` returns the
Task, artifacts, recursive subtasks, and backlinks and is explicitly described
as suitable for Ralph-style handoffs
([`get_task`, lines 892-1035](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L892-L1035),
[`load_context`, lines 2431-2514](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L2431-L2514)).

Use `update_task` or typed `transact_tasks` operations with a fresh revision for
progress and completion. Branch on machine-readable `error` and `outcome`
fields, never message text. Mutation success is `applied` or `no_op`; important
errors include `conflict`, `precondition_required`, `validation_error`,
`mutation_id_reused`, `not_found`, and `operation_failed`
([outcome serializer, lines 3008-3030](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L3008-L3030)).

## 6. Delivery evidence

Glasswork offers three evidence mechanisms:

1. **Artifacts:** `add_artifact` creates or conditionally overwrites text
   artifacts in `<task-id>.artifacts/`, with the same mutation id and revision
   preconditions as Tasks. MCP accepts `.md`, `.txt`, `.html`, and `.htm`.
   Results include the artifact revision. Glasswork does not write back to
   artifact bodies
   ([tool, lines 1059-1199](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L1059-L1199),
   [artifact contract](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/docs/agent-contract.md)).
2. **Typed links:** `add_link` appends `pr`, `build`, `ado`, `incident`, `doc`, or
   `other` links under revision control. It does not de-duplicate, so Ralph must
   read before appending on retries
   ([lines 3436-3508](https://github.com/tjegbejimba/Glasswork/blob/508634c48c090d8f35031c410f3cc368c78244b6/src/Glasswork.Mcp/Tools/GlassworkTools.cs#L3436-L3508)).
3. **Notes:** `update_task` can append unstructured notes. Use this only for a
   compact human-readable run log, not evidence Ralph must parse later.

Binary evidence cannot be uploaded through MCP. The first-party artifact
contract allows direct binary writes to the artifact directory only through its
required temporary-file-to-atomic-rename protocol. That is narrower than direct
Task mutation: artifacts are agent-owned content and Glasswork treats them as
read-only. Ralph should prefer a text summary artifact plus typed PR/build links,
and use the direct binary protocol only when necessary.

## 7. Recommended Node integration

1. Resolve the installed executable, verify an exact allowed
   `version+commit`, set `GLASSWORK_VAULT`, spawn over stdio, and capture stderr.
2. Call `get_capabilities`, require the complete contract, and verify required
   tools in `tools/list`.
3. Poll `query_tasks` for eligible `todo` work; retain the Task revision and
   relation-aware `read_basis`.
4. Attempt the `todo` -> `doing` CAS with a deterministic mutation id. Treat a
   conflict as a lost race and re-plan from the returned current snapshot.
5. Keep worker identity, heartbeat, lease expiry, stale-work detection, and
   operator-visible reclaim policy in Ralph. Glasswork ownership tags are
   advisory only.
6. Update progress through conditional MCP mutations. Re-read after any
   conflict rather than overwriting another actor's changes.
7. Attach a structured text artifact and typed PR/build links as delivery
   evidence, then set status to `done` with a fresh revision.
8. Use `cancel_task`, not hard deletion, for abandoned work.

## 8. Unsupported or unsafe assumptions

Do not assume:

- a claim, owner, lease, heartbeat, expiry, reclaim, or fencing API exists;
- `doing` proves a live worker owns the Task;
- Resource Revisions are monotonic or order events;
- direct Task-file writes participate in managed CAS or locking;
- the `Local\` named mutex coordinates across Windows sessions or unmanaged
  writers;
- custom frontmatter is a supported extension point;
- server startup proves vault readiness;
- the README's tool table and status vocabulary are complete;
- `0.x` tool shapes are stable across minor versions;
- silent id sanitization cannot alias two caller-supplied ids;
- `add_task` resolves title collisions;
- a cancelled Task can be updated before restoration;
- hard deletion is a normal completion operation;
- artifact filenames are immutable, or `add_link` is idempotently de-duplicated;
- Glasswork emits a change feed; Ralph must poll.

## Research limits

This report establishes contract behavior from first-party source, ADRs, and
published contract documentation at one pinned commit. The Glasswork test suites
were not executed, latency was not benchmarked, NuGet publication was not
confirmed, and non-Windows named-mutex behavior was not verified. Those limits
do not change the interface or claim-model conclusion, but they should be closed
before treating a production adapter as cross-platform or assigning an SLO.
