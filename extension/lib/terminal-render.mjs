// terminal-render.mjs — ANSI formatters for Ralph status payloads.
//
// Pure functions: take a payload (the shape produced by createStatusReader's
// buildStatusPayload / buildLocalPayload) and return a string for stdout.
// Honours NO_COLOR and TERM=dumb so we don't dump escape codes into logs.

const COLORS = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
  gray: "\x1b[90m",
};

export function shouldUseColor(env = process.env, opts = {}) {
  if (opts.color === false) return false;
  if (opts.color === true) return true;
  if (env.NO_COLOR) return false;
  if (env.TERM === "dumb") return false;
  return true;
}

function makeColorize(useColor) {
  return (text, color) => {
    if (!useColor) return text;
    const code = COLORS[color];
    return code ? `${code}${text}${COLORS.reset}` : text;
  };
}

function fmtAge(seconds) {
  if (seconds == null) return "—";
  if (seconds < 60) return `${seconds}s`;
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m < 60) return `${m}m${s ? ` ${s}s` : ""}`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  return `${h}h${rm ? ` ${rm}m` : ""}`;
}

function fmtRuntime(startedAt) {
  if (!startedAt) return "—";
  const t = Date.parse(startedAt);
  if (Number.isNaN(t)) return "—";
  return fmtAge(Math.floor((Date.now() - t) / 1000));
}

function fmtTokens(tokens) {
  if (!tokens || tokens.total == null) return null;
  const fmt = (n) => {
    if (n == null) return "0";
    if (n >= 1e6) return `${(n / 1e6).toFixed(1)}m`;
    if (n >= 1e3) return `${(n / 1e3).toFixed(1)}k`;
    return String(n);
  };
  return `↑${fmt(tokens.input)} ↓${fmt(tokens.output)}${tokens.iterations ? ` · ${tokens.iterations} iter` : ""}`;
}

function header(text, color, c) {
  return c(`── ${text} ${"─".repeat(Math.max(2, 60 - text.length))}`, color);
}

// Render the current-iterations block. Each worker row shows: worker id,
// issue #, stage, runtime, last-write age, and a "stale claim" or "stuck"
// hint when warranted.
export function renderWorkers(workers, c) {
  if (!workers || workers.length === 0) {
    return c("  (no active workers)", "dim");
  }
  const lines = [];
  for (const w of workers) {
    const stage = w.stage || { icon: "○", label: "starting" };
    const wid = w.workerId != null ? `w${w.workerId}` : "w?";
    const issue = w.issue ? `#${w.issue}` : "#?";
    const runtime = fmtRuntime(w.startedAt);
    const lastWrite = w.ageSec != null ? `idle ${fmtAge(w.ageSec)}` : "no log yet";
    const tokens = fmtTokens(w.cumulativeTokens);

    let statusHint = "";
    if (w.pid != null && w.pidAlive === false) {
      statusHint = ` ${c("⚠ claim stale — run launch.sh --cleanup", "red")}`;
    } else if (w.stuck) {
      statusHint = ` ${c("⚠ stuck >5m", "yellow")}`;
    }

    const stageStr = `${stage.icon} ${stage.label}`;
    const head = `  ${c(wid, "cyan")} ${c(issue, "bold")}  ${c(stageStr, "magenta")}`;
    const meta = `    ${c(`runtime ${runtime} · ${lastWrite}`, "dim")}${tokens ? c(` · ${tokens}`, "dim") : ""}${statusHint}`;
    lines.push(head);
    lines.push(meta);

    if (w.currentPr) {
      const pr = w.currentPr;
      const checks = pr.checks || {};
      const checksStr = checks.total
        ? ` checks ${checks.pass}✓/${checks.fail}✗/${checks.pending}⏱`
        : "";
      const draft = pr.isDraft ? " [draft]" : "";
      lines.push(`    ${c(`PR #${pr.number}${draft}${checksStr}`, "blue")}`);
    }
  }
  return lines.join("\n");
}

// Render the queue progress block from the resolved active run's status.json
// items. Surfaces .error inline for failed items.
export function renderQueueProgress(activeRun, c) {
  if (!activeRun) {
    return c("  (no run history)", "dim");
  }
  const items = activeRun.statusData?.items || {};
  const entries = Object.entries(items);
  if (entries.length === 0) {
    return c(`  ${activeRun.runId}: (queue empty)`, "dim");
  }
  const counts = { merged: 0, running: 0, claimed: 0, queued: 0, failed: 0, skipped: 0, other: 0 };
  for (const [, v] of entries) {
    const s = v?.status || "other";
    if (counts[s] != null) counts[s] += 1;
    else counts.other += 1;
  }
  const label = activeRun.isActive ? "active run" : "latest run";
  const summary = `  ${c(`${label}:`, "bold")} ${activeRun.runId}  ` +
    `${c(`${counts.merged}✓ merged`, "green")} · ` +
    `${c(`${counts.running}⚙ running`, "cyan")} · ` +
    `${c(`${counts.claimed}● claimed`, "blue")} · ` +
    `${c(`${counts.queued}○ queued`, "dim")} · ` +
    `${c(`${counts.failed}✗ failed`, counts.failed ? "red" : "dim")} · ` +
    `${c(`${counts.skipped}⤼ skipped`, "dim")}`;

  const lines = [summary];

  // Show failed items inline with their error
  const failed = entries.filter(([, v]) => v?.status === "failed");
  for (const [issue, v] of failed) {
    const err = v?.error ? `: ${v.error}` : "";
    lines.push(c(`    ✗ #${issue}${err}`, "red"));
  }

  // Show running items so users can correlate workers with queue rows
  const running = entries.filter(([, v]) => v?.status === "running" || v?.status === "claimed");
  for (const [issue, v] of running) {
    const w = v?.workerId != null ? ` (w${v.workerId})` : "";
    lines.push(c(`    ${v.status === "running" ? "⚙" : "●"} #${issue}${w}`, "cyan"));
  }

  return lines.join("\n");
}

export function renderLoopTail(loopOutTail, c, opts = {}) {
  if (!loopOutTail) return c("  (loop.out is empty)", "dim");
  const maxLines = opts.maxLines || 15;
  const lines = loopOutTail.split("\n").filter((l) => l.length > 0).slice(-maxLines);
  if (lines.length === 0) return c("  (loop.out is empty)", "dim");
  return lines.map((l) => c(`  ${l}`, "dim")).join("\n");
}

// Local-only renderer: workers + queue + loop tail. Used by --watch.
export function renderLocalStatus(payload, opts = {}) {
  const useColor = shouldUseColor(process.env, opts);
  const c = makeColorize(useColor);
  const now = new Date(payload.timestamp || Date.now()).toLocaleTimeString();
  const out = [];
  out.push(c(`Ralph status @ ${now}`, "bold"));
  out.push(c(`  ${payload.repoRoot || ""}`, "dim"));
  out.push("");
  out.push(header("Workers", "bold", c));
  out.push(renderWorkers(payload.workers || [], c));
  out.push("");
  out.push(header("Queue progress", "bold", c));
  out.push(renderQueueProgress(payload.activeRun, c));
  out.push("");
  out.push(header("loop.out (tail)", "bold", c));
  out.push(renderLoopTail(payload.loopOutTail, c));
  return out.join("\n");
}

// Full renderer: includes processes, recent PRs, header line. Used by --status.
export function renderStatus(payload, opts = {}) {
  const useColor = shouldUseColor(process.env, opts);
  const c = makeColorize(useColor);
  const out = [];

  if (payload.headerText) {
    out.push(c(payload.headerText, "bold"));
  }
  const now = new Date(payload.timestamp || Date.now()).toLocaleTimeString();
  out.push(c(`Ralph status @ ${now} · loop ${payload.loopRunning ? c("running", "green") : c("idle", "yellow")}`, "bold"));
  out.push("");

  out.push(header("Workers", "bold", c));
  out.push(renderWorkers(payload.workers || [], c));
  out.push("");

  out.push(header("Queue progress", "bold", c));
  out.push(renderQueueProgress(payload.activeRun, c));
  out.push("");

  if (opts.withPrs && Array.isArray(payload.recentPrs) && payload.recentPrs.length > 0) {
    out.push(header("Recent PRs", "bold", c));
    for (const pr of payload.recentPrs.slice(0, 5)) {
      const state = pr.state === "MERGED" ? c("merged", "green") :
        pr.state === "OPEN" ? c("open", "blue") :
        c(pr.state.toLowerCase(), "dim");
      out.push(`  ${c(`#${pr.number}`, "bold")} ${state} · ${pr.title}`);
    }
    out.push("");
  }

  out.push(header("loop.out (tail)", "bold", c));
  out.push(renderLoopTail(payload.loopOutTail, c));

  return out.join("\n");
}
