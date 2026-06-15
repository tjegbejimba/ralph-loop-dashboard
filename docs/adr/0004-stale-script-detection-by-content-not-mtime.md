# Stale-script detection by content, not mtime

This repo is self-hosting: it is both the **source** of the Ralph automation
(`ralph/ralph.sh`, `ralph/launch.sh`, `ralph/lib/*`, `ralph/profiles/*`, tracked)
and a repo **managed by** that same automation. `install.sh` copies the source
into a per-checkout `.ralph/` tree (untracked, hidden via `.git/info/exclude`),
preserving `.ralph/config.json` and `.ralph/RALPH.md` as per-repo customization.
The copies under `.ralph/` are what autonomous workers actually execute.

`launch.sh` carries a stale-script guard (`ralph/launch.sh`, ~L786–801) so workers
never silently run an out-of-date installed copy after a fix lands in source. The
guard compares the **mtime** of `ralph/ralph.sh` (source) against `.ralph/ralph.sh`
(installed) and refuses to launch when the source is newer.

In the self-hosting checkout this guard is a footgun (issue #131). Git does not
preserve or track mtimes: every `checkout`/`merge` stamps working-tree files with
"now". So each time `main` advances — e.g. a Ralph worker merges a slice PR — git
rewrites `ralph/ralph.sh`'s mtime, the guard trips even though the **content** is
byte-for-byte unchanged, and `launch.sh` exits 1 on the next autonomous tick. The
orchestrator is forbidden from installing/repairing during a tick, so the guard
cannot self-heal; unattended operation hard-stops until a human runs
`install.sh --scripts-only`. This defeats the loop precisely for the repo meant to
dogfood it.

A survey of how other self-hosting / bootstrapping / committed-generated-artifact
systems handle "a source copy and an installed/vendored copy that can drift" found
a consistent answer: **staleness is decided by content, never by timestamp**, and
the dogfooding checkout tends toward a **single source of truth** rather than two
copies racing on filesystem metadata.

- Bootstrapping compilers pin a known-good and compare content/output: TypeScript
  builds with the checked-in **LKG** ("Last Known Good") compiler; GCC's 3-stage
  bootstrap **byte-compares** stage2 vs stage3; Go pins `GOROOT_BOOTSTRAP` to a
  declared minimum version; rustc pins a hash-checked stage0.
- Self-applying linters/formatters (Black, Prettier, gofmt, rustfmt, ruff, clippy)
  detect drift with a **content diff** in CI (`--check`, `-l`, `git diff
  --exit-code`). None refuse to *run* on a timestamp.
- GitOps tools that manage themselves (Argo CD app-of-apps, Flux `flux bootstrap`)
  reconcile from **one Git source of truth**, not a vendored duplicate.
- Self-updating package managers (rustup, Homebrew, npm, pip) **hash-validate** a
  download then **atomically `rename()`** it into place; staleness means "hash
  differs".
- The committed-generated-artifact pattern (`go generate`, protobuf, mocks,
  lockfiles) enforces freshness with `<regenerate> && git diff --exit-code` and
  content hashes (`npm ci --frozen-lockfile`, `go.sum`, `go mod verify`).

## Decision

We adopt three decisions; they are independent and ship separately.

1. **Staleness is determined by content, never by mtime.** The stale-script guard
   compares source and installed scripts by **content** — a per-file `cmp -s` (or
   sha256) across `ralph.sh`, `launch.sh`, `lib/*`, and `profiles/*`. The guard
   blocks only when content genuinely diverges. Byte-identical files with a newer
   source mtime (the merge case) are treated as fresh. This is the immediate fix
   for issue #131 and is the smallest, lowest-risk change.

2. **In the self-hosting checkout, the installed scripts are a single source of
   truth via symlinks.** `install.sh` detects when the target *is* the Ralph source
   repo (`REPO_DIR -ef TARGET`) and, for that case only, symlinks the executable
   surface — `.ralph/ralph.sh`, `.ralph/launch.sh`, `.ralph/lib/`,
   `.ralph/profiles/` — to the tracked `ralph/*` sources, while keeping
   `.ralph/config.json`, `.ralph/RALPH.md`, and runtime state (`runs/`,
   `state.json`, `logs/`) as real per-repo files. Source then ≡ installed by
   construction and the guard can never trip in the dogfooding repo. **Foreign
   target repos keep the existing `cp` vendoring** — they have no `ralph/` source,
   so a real per-repo copy remains the correct delivery mechanism. This is tracked
   as a separate follow-up: the "symlink restructure" (#138).

3. **Drift is enforced by a CI content-diff gate, not a runtime hard-stop.** A
   `install.sh --check` mode performs a content diff of `ralph/` against `.ralph/`
   and exits non-zero on divergence, run as a CI job (the `go generate && git diff
   --exit-code` pattern). Once CI covers genuine drift at PR time, the runtime guard
   becomes **warn-only** rather than a launch-blocking hard-stop. This is tracked as
   a separate follow-up: the "CI drift gate" (#139).

Decision 1 closes #131 on its own and should land first; decisions 2 and 3 are
tracked as #138 (symlink restructure) and #139 (CI drift gate), both blocked by #131. Decisions 2 and 3 are the
durable architecture: together they make the duplicate structurally unable to drift
and move enforcement to where a human can act, so an unattended worker is never
hard-stopped by the guard again.

## Consequences

- Advancing `main` (a merge) without changing script content no longer trips the
  guard; autonomous ticks after a merged worker PR launch without manual
  `install.sh --scripts-only`.
- The guard still blocks when installed script **content** genuinely diverges from
  source, preserving the original protection.
- In the self-hosting checkout (decision 2) drift is impossible by construction,
  and the recurring `.github/copilot-instructions.md` re-append churn from repeated
  `install.sh --scripts-only` recovery runs disappears.
- Foreign repos are unaffected: they keep copy semantics and a content-based guard.
- With the CI gate (decision 3) covering drift, the runtime guard's job shrinks to a
  warning, so a single perturbed file can never hard-stop an unattended run.
- Symlinked executables in the dogfooding checkout mean an edit to `ralph/*` is
  immediately live in `.ralph/*` with no reinstall — convenient for development,
  but it removes the "install step" as a deliberate promotion boundary in that one
  checkout. The CI content gate and normal review remain the safety net.

## Alternatives considered

- **Keep mtime comparison (status quo).** Rejected. mtime is not a meaningful
  staleness signal in a git working tree: checkout/merge rewrite it independently of
  content, which is the entire cause of #131. Every surveyed prior-art system avoids
  timestamps for exactly this reason.

- **Touch the installed copy's mtime after each merge.** Rejected as a fix. It
  papers over the wrong signal, must run on every merge, and the orchestrator is
  forbidden from repairing state during a tick — so it cannot self-heal where it
  matters.

- **Version/hash sentinel instead of per-file content comparison.** Embed a
  version/hash constant in `ralph.sh`, have `install.sh` record the installed-from
  hash in `.ralph/.installed-from`, and compare recorded-vs-current source hash —
  one comparison, git-aware, mtime-immune (analogous to Go's `GOROOT_BOOTSTRAP` pin
  and rustc's stage0 hash). A reasonable design, but it adds a sentinel file and a
  promotion ritual for marginal benefit over decision 1's direct per-file `cmp`,
  which already reports *which* file diverged. Kept as a fallback if per-file
  hashing ever proves too costly.

- **Run workers directly from `ralph/` source with no `.ralph/` copy at all.**
  Rejected as the general model. `.ralph/` holds per-repo customization
  (`config.json`, `RALPH.md`) and runtime state, and is the vendoring mechanism for
  foreign repos that have no `ralph/` source. Decision 2 captures the *self-hosting*
  benefit of this idea (single source of truth) via symlinks without removing the
  vendored-copy delivery path that foreign repos depend on.
