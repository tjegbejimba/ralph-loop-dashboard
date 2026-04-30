const REFRESH_MS = 8000;

const $ = (id) => document.getElementById(id);

function fmtDuration(ms) {
  if (ms < 0) return "0s";
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rs = s % 60;
  if (m < 60) return `${m}m ${rs}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

function fmtTime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function escapeHtml(s) {
  return String(s).replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
}

function renderPrCardHtml(pr) {
  if (!pr) return "";
  if (pr.error) {
    return `<div class="pr-card"><div class="pr-card-error">PR lookup failed: ${escapeHtml(pr.error)}</div></div>`;
  }
  const ck = pr.checks;
  const ckBadge =
    ck.total === 0
      ? '<span class="check-pill pending">no checks yet</span>'
      : `<span class="check-pill ${ck.fail ? "fail" : ck.pending ? "pending" : "pass"}">
           ${ck.pass}✓ ${ck.fail}✗ ${ck.pending}○
         </span>`;
  const review = pr.reviewDecision
    ? `<span class="check-pill ${pr.reviewDecision === "APPROVED" ? "pass" : pr.reviewDecision === "CHANGES_REQUESTED" ? "fail" : "pending"}">
         ${pr.reviewDecision.toLowerCase().replace(/_/g, " ")}
       </span>`
    : "";
  const draft = pr.isDraft ? '<span class="check-pill pending">draft</span>' : "";
  return `
    <div class="pr-card">
      <div class="pr-card-head">
        <a href="${escapeHtml(pr.url)}" target="_blank" class="pr-card-title">
          <span class="pr-card-num">#${pr.number}</span>
          <span class="pr-card-text">${escapeHtml(pr.title)}</span>
        </a>
        ${draft}
        ${ckBadge}
        ${review}
      </div>
      <div class="pr-card-meta">
        <span class="add">+${pr.additions.toLocaleString()}</span>
        <span class="del">−${pr.deletions.toLocaleString()}</span>
        · ${pr.changedFiles} file${pr.changedFiles === 1 ? "" : "s"}
        · ${pr.commitCount} commit${pr.commitCount === 1 ? "" : "s"}
      </div>
    </div>
  `;
}

function renderWorkerCardHtml(it, isLive) {
  const elapsed = fmtDuration(Date.now() - new Date(it.startedAt).getTime());
  const statusLabel = isLive ? "● running" : "○ last (loop stopped)";
  const statusClass = isLive ? "accent" : "purple";
  const stage = it.stage || { stage: "starting", label: "starting", icon: "○" };
  const ageSec = it.ageSec ?? 0;
  const heartbeatTitle = it.stuck
    ? "Loop may be stuck — no log writes >5min"
    : it.lastWriteAt
      ? `last log write at ${fmtTime(it.lastWriteAt)}`
      : "no writes yet";
  const reviewLabel = it.reviewStats
    ? `review: gpt ${it.reviewStats.gpt}× · opus ${it.reviewStats.opus}×`
    : "review: not yet";
  const reviewClass = it.reviewStats ? "ok" : "";
  const tokensHtml =
    it.tokens != null
      ? `<span class="strip-item">tokens: ${it.tokens.toLocaleString()}</span>`
      : "";
  const workerLabel =
    it.workerId != null
      ? `<span class="worker-pill">worker ${it.workerId}</span>`
      : "";
  return `
    <div class="worker-card${it.stuck ? " stuck" : ""}">
      <div class="worker-card-head">
        ${workerLabel}
        <span class="stage-badge stage-${stage.stage}">${stage.icon} ${stage.label}</span>
      </div>
      <div class="worker-card-body">
        <span class="field"><span class="label">status:</span><span class="val ${statusClass}">${statusLabel}</span></span>
        <span class="field"><span class="label">issue:</span><span class="val">#${it.issue}</span></span>
        <span class="field"><span class="label">started:</span><span class="val">${fmtTime(it.startedAt)}</span></span>
        <span class="field"><span class="label">elapsed:</span><span class="val">${elapsed}</span></span>
      </div>
      <div class="worker-card-log-meta">${escapeHtml(it.logFile || "(no log)")}</div>
      <div class="iteration-strip">
        <span class="strip-item${it.stuck ? " warn" : ""}" title="${escapeHtml(heartbeatTitle)}">
          last write: ${ageSec ? fmtDuration(ageSec * 1000) + " ago" : "—"}
        </span>
        <span class="strip-item ${reviewClass}">${reviewLabel}</span>
        ${tokensHtml}
      </div>
      ${renderPrCardHtml(it.currentPr)}
      <pre class="log">${escapeHtml(it.tail || "(no log content)")}</pre>
    </div>
  `;
}

// --- Desktop notifications on transitions ---

const notifyState = { lastMergedNum: null, lastIssues: null, stuckIssues: null };

function notify(title, body) {
  if (typeof Notification === "undefined") return;
  if (Notification.permission === "granted") {
    try {
      new Notification(title, { body, silent: false });
    } catch {}
  }
}

function maybeNotify(s) {
  const workers = Array.isArray(s.workers) ? s.workers : [];
  // Track issues currently in flight; notify when a NEW one appears.
  const currentIssues = new Set(workers.map((w) => w.issue));
  if (notifyState.lastIssues) {
    for (const issue of currentIssues) {
      if (!notifyState.lastIssues.has(issue)) {
        notify("Ralph: new iteration", `Working on #${issue}`);
      }
    }
  }
  notifyState.lastIssues = currentIssues;

  // Stuck warning — fire once per (issue, stuck-edge).
  if (!notifyState.stuckIssues) notifyState.stuckIssues = new Set();
  for (const w of workers) {
    if (w.stuck && !notifyState.stuckIssues.has(w.issue)) {
      notifyState.stuckIssues.add(w.issue);
      notify("Ralph: worker may be stuck", `#${w.issue} — no log writes for ${fmtDuration(w.ageSec * 1000)}`);
    } else if (!w.stuck) {
      notifyState.stuckIssues.delete(w.issue);
    }
  }

  // PR merged — same as before.
  const lastMerged = (s.recentPrs || []).find((p) => p.state === "MERGED");
  if (
    lastMerged &&
    notifyState.lastMergedNum !== null &&
    lastMerged.number !== notifyState.lastMergedNum
  ) {
    notify("Ralph: PR merged 🎉", `#${lastMerged.number} ${lastMerged.title}`);
  }
  if (lastMerged) notifyState.lastMergedNum = lastMerged.number;
}

// Ask once on first user click anywhere on the page (browsers gate notifications behind a gesture)
function setupNotifications() {
  if (typeof Notification === "undefined") return;
  if (Notification.permission === "default") {
    document.addEventListener(
      "click",
      () => {
        Notification.requestPermission().catch(() => {});
      },
      { once: true },
    );
  }
}
setupNotifications();

function sliceNumFromTitle(title) {
  const m = title.match(/^Slice (\d+):/);
  return m ? Number(m[1]) : null;
}

function render(s) {
  const dot = $("status-dot");
  dot.classList.remove("green", "red", "yellow");
  if (s.loopRunning) dot.classList.add("green");
  else if (s.openSlices && s.openSlices.length === 0) dot.classList.add("yellow");
  else dot.classList.add("red");

  // Toggle Start/Stop visibility based on loop state.
  const startBtn = $("start-btn");
  const stopBtn = $("stop-btn");
  if (startBtn && stopBtn) {
    startBtn.hidden = s.loopRunning;
    stopBtn.hidden = !s.loopRunning;
  }

  $("last-updated").textContent = `updated ${fmtTime(s.timestamp)}`;

  // Active workers — render one card per active iteration.
  const workersContainer = $("workers-container");
  const workers = Array.isArray(s.workers) ? s.workers : [];
  const workersCount = $("workers-count");
  if (workersCount) {
    workersCount.textContent = workers.length === 0 ? "—" : `${workers.length} active`;
  }
  if (workers.length === 0) {
    workersContainer.classList.remove("multi");
    workersContainer.innerHTML =
      '<div class="placeholder">no active workers</div>';
  } else {
    workersContainer.classList.toggle("multi", workers.length > 1);
    workersContainer.innerHTML = workers
      .map((w) => renderWorkerCardHtml(w, s.loopRunning))
      .join("");
  }
  maybeNotify(s);

  // Cumulative stats
  if (s.cumulative) {
    const c = s.cumulative;
    $("cumulative-stats").textContent =
      c.mergedToday === 0
        ? "no merges yet"
        : `${c.mergedToday} PR${c.mergedToday === 1 ? "" : "s"} · +${c.additions.toLocaleString()} / −${c.deletions.toLocaleString()} · ${c.changedFiles} file${c.changedFiles === 1 ? "" : "s"}`;
  }

  // Queue
  const queue = $("queue-list");
  queue.classList.remove("placeholder");
  $("queue-count").textContent = s.openSlices ? s.openSlices.length : "—";
  if (!s.openSlices || s.openSlices.length === 0) {
    queue.innerHTML = '<li class="placeholder">no open slices 🎉</li>';
  } else {
    queue.innerHTML = s.openSlices
      .map((i, idx) => {
        const slice = sliceNumFromTitle(i.title);
        const cleanTitle = i.title.replace(/^Slice \d+:\s*/, "");
        return `
                    <li class="${idx === 0 ? "first-up issue-row" : "issue-row"}" data-issue="${i.number}" data-url="${escapeHtml(i.url)}">
                        <div class="issue-head">
                            <span class="slice-num">${slice ?? "?"}</span>
                            <span class="issue-num">#${i.number}</span>
                            <span class="issue-title">${escapeHtml(cleanTitle)}</span>
                            <span class="issue-toggle" aria-hidden="true">▸</span>
                        </div>
                        <div class="issue-detail" hidden></div>
                    </li>
                `;
      })
      .join("");
    queue.querySelectorAll(".issue-row").forEach((li) => {
      li.querySelector(".issue-head").addEventListener("click", (ev) => {
        if (ev.target.closest("a")) return;
        toggleIssueDetail(li);
      });
      if (openIssues.has(Number(li.dataset.issue))) {
        renderIssueDetail(li, /* skipToggle */ true);
      }
    });
  }

  // PRs
  const prs = $("prs-list");
  prs.classList.remove("placeholder");
  if (!s.recentPrs || s.recentPrs.length === 0) {
    prs.innerHTML = '<li class="placeholder">no recent PRs</li>';
  } else if (s.recentPrs.error) {
    prs.innerHTML = `<li class="error">${escapeHtml(s.recentPrs.error)}</li>`;
  } else {
    prs.innerHTML = s.recentPrs
      .slice(0, 8)
      .map((p) => {
        const when = p.mergedAt ? fmtTime(p.mergedAt) : "—";
        return `
                    <li class="pr-row" data-pr-number="${p.number}" tabindex="0" role="button">
                        <span class="pr-state ${p.state}">${p.state}</span>
                        <span class="issue-num">#${p.number}</span>
                        <span class="issue-title">${escapeHtml(p.title)}</span>
                        <span class="issue-num" style="margin-left:auto">${when}</span>
                    </li>
                `;
      })
      .join("");
  }

  renderHistory(s.iterationHistory);
}

function renderHistory(h) {
  const list = $("history-list");
  if (!list) return;
  list.classList.remove("placeholder");
  if (!h || !h.iterations || h.iterations.length === 0) {
    list.innerHTML = '<li class="placeholder">no iteration logs yet</li>';
    $("history-stats").textContent = "—";
    return;
  }
  if (h.stats) {
    const avg = fmtDuration(h.stats.avgDurationMs);
    $("history-stats").textContent =
      `${h.stats.last24h} in 24h · avg ${avg} · ${h.stats.total} total`;
  }
  list.innerHTML = h.iterations
    .map((it) => {
      const dur = fmtDuration(it.durationMs);
      const cls = it.status === "open" ? "OPEN" : "MERGED";
      const label = it.status === "open" ? "···" : "✓";
      const href = it.prUrl ? ` href="${escapeHtml(it.prUrl)}" target="_blank"` : "";
      const titleAttr = `title="${escapeHtml(it.logFile)}"`;
      const workerTag =
        it.workerId != null
          ? `<span class="worker-pill small">w${it.workerId}</span>`
          : "";
      return `
                <li ${titleAttr}>
                    <span class="pr-state ${cls}">${label}</span>
                    <span class="slice-num">#${it.issue}</span>
                    ${workerTag}
                    <span class="issue-title">${href ? `<a${href}>` : ""}${fmtTime(it.startedAt)}${href ? "</a>" : ""}</span>
                    <span class="issue-num" style="margin-left:auto">${dur}</span>
                </li>
            `;
    })
    .join("");
}

async function refresh() {
  try {
    const status = await copilot.getStatus();
    render(status);
  } catch (err) {
    $("last-updated").textContent = `error: ${err.message || err}`;
  }
}

$("refresh-btn").addEventListener("click", refresh);

// --- Loop start/stop controls ---

async function handleStart() {
  const btn = $("start-btn");
  btn.disabled = true;
  btn.textContent = "starting…";
  try {
    const res = await copilot.startLoop();
    if (!res?.ok) {
      $("last-updated").textContent = `start failed: ${res?.error || "unknown"}`;
    }
  } catch (err) {
    $("last-updated").textContent = `start failed: ${err.message || err}`;
  } finally {
    btn.disabled = false;
    btn.textContent = "▶ Start loop";
    refresh();
  }
}

async function handleStop() {
  if (!confirm("Stop the Ralph loop? In-flight iteration will be terminated.")) return;
  const btn = $("stop-btn");
  btn.disabled = true;
  btn.textContent = "stopping…";
  try {
    const res = await copilot.stopLoop();
    if (!res?.ok) {
      $("last-updated").textContent = `stop failed: ${res?.error || "unknown"}`;
    }
  } catch (err) {
    $("last-updated").textContent = `stop failed: ${err.message || err}`;
  } finally {
    btn.disabled = false;
    btn.textContent = "■ Stop loop";
    setTimeout(refresh, 500);
  }
}

$("start-btn")?.addEventListener("click", handleStart);
$("stop-btn")?.addEventListener("click", handleStop);

refresh();
setInterval(refresh, REFRESH_MS);

// --- Detail drawer (PRs) ---

const drawer = $("detail-drawer");
const detailTitle = $("detail-title");
const detailBody = $("detail-body");

function openDrawer() {
  drawer.classList.remove("hidden");
  drawer.setAttribute("aria-hidden", "false");
}
function closeDrawer() {
  drawer.classList.add("hidden");
  drawer.setAttribute("aria-hidden", "true");
}

function renderMarkdown(body) {
  if (!body) return '<p class="placeholder">(no description)</p>';
  const esc = escapeHtml(body);
  const withCode = esc.replace(/`([^`]+)`/g, "<code>$1</code>");
  const paragraphs = withCode.split(/\n{2,}/).map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`);
  return paragraphs.join("");
}

function renderPrDetail(pr) {
  if (!pr || pr.error) {
    detailTitle.textContent = "Error";
    detailBody.innerHTML = `<p class="error">${escapeHtml(pr?.error || "unknown error")}</p>`;
    return;
  }
  const stateClass = pr.state || "OPEN";
  const labels = (pr.labels || [])
    .map((l) => `<span class="label">${escapeHtml(l.name)}</span>`)
    .join(" ");
  const author = pr.author?.login ? `@${pr.author.login}` : "—";
  const merged = pr.mergedAt ? new Date(pr.mergedAt).toLocaleString() : "";
  const created = pr.createdAt ? new Date(pr.createdAt).toLocaleString() : "—";
  const closed = pr.closedAt && !pr.mergedAt ? new Date(pr.closedAt).toLocaleString() : "";
  const draftBadge = pr.isDraft ? '<span class="pr-state DRAFT">DRAFT</span>' : "";

  detailTitle.textContent = `#${pr.number} ${pr.title}`;
  detailBody.innerHTML = `
    <div class="detail-meta">
      <span class="pr-state ${stateClass}">${stateClass}</span>
      ${draftBadge}
      ${labels}
    </div>
    <dl class="detail-stats">
      <dt>Author</dt><dd>${escapeHtml(author)}</dd>
      <dt>Branch</dt><dd><code>${escapeHtml(pr.headRefName || "?")}</code> → <code>${escapeHtml(pr.baseRefName || "?")}</code></dd>
      <dt>Files</dt><dd>${pr.changedFiles ?? 0} changed (<span class="add">+${pr.additions ?? 0}</span> / <span class="del">−${pr.deletions ?? 0}</span>)</dd>
      <dt>Created</dt><dd>${created}</dd>
      ${merged ? `<dt>Merged</dt><dd>${merged}</dd>` : ""}
      ${closed ? `<dt>Closed</dt><dd>${closed}</dd>` : ""}
    </dl>
    <a class="detail-link" href="${escapeHtml(pr.url || "#")}" target="_blank">View on GitHub ↗</a>
    <h4>Description</h4>
    <div class="detail-body-md">${renderMarkdown(pr.body)}</div>
  `;
}

async function showPrDetail(number) {
  detailTitle.textContent = `#${number} Loading…`;
  detailBody.innerHTML = '<p class="placeholder">fetching from gh…</p>';
  openDrawer();
  try {
    const pr = await copilot.getPrDetail(number);
    renderPrDetail(pr);
  } catch (err) {
    renderPrDetail({ error: String(err?.message || err) });
  }
}

$("prs-list").addEventListener("click", (e) => {
  const row = e.target.closest(".pr-row");
  if (!row) return;
  const num = Number(row.dataset.prNumber);
  if (Number.isInteger(num)) showPrDetail(num);
});
$("prs-list").addEventListener("keydown", (e) => {
  if (e.key !== "Enter" && e.key !== " ") return;
  const row = e.target.closest(".pr-row");
  if (!row) return;
  e.preventDefault();
  const num = Number(row.dataset.prNumber);
  if (Number.isInteger(num)) showPrDetail(num);
});

$("detail-close").addEventListener("click", closeDrawer);
drawer.addEventListener("click", (e) => {
  if (e.target.dataset.close === "1") closeDrawer();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !drawer.classList.contains("hidden")) closeDrawer();
});

// --- Inline issue detail expansion (Queue) ---

const detailCache = new Map();
const openIssues = new Set();
window.__openIssues = openIssues;
window.__detailCache = detailCache;

async function toggleIssueDetail(li) {
  const detail = li.querySelector(".issue-detail");
  const toggle = li.querySelector(".issue-toggle");
  const issueNum = Number(li.dataset.issue);
  if (!detail.hidden) {
    detail.hidden = true;
    toggle.textContent = "▸";
    openIssues.delete(issueNum);
    return;
  }
  openIssues.add(issueNum);
  await renderIssueDetail(li);
}

async function renderIssueDetail(li) {
  const detail = li.querySelector(".issue-detail");
  const toggle = li.querySelector(".issue-toggle");
  const issueNum = Number(li.dataset.issue);
  const url = li.dataset.url;
  toggle.textContent = "▾";
  if (!detailCache.has(issueNum)) {
    detail.innerHTML = '<div class="placeholder">loading…</div>';
    detail.hidden = false;
    try {
      const data = await copilot.getIssueDetail(issueNum);
      detailCache.set(issueNum, data);
    } catch (err) {
      detail.innerHTML = `<div class="error">${escapeHtml(err.message || err)}</div>`;
      return;
    }
  }
  const data = detailCache.get(issueNum);
  if (data?.error) {
    detail.innerHTML = `<div class="error">${escapeHtml(data.error)}</div>`;
    detail.hidden = false;
    return;
  }
  const labels = (data.labels || [])
    .map(
      (l) =>
        `<span class="label-chip" style="background:#${l.color || "30363d"}33;color:#${l.color || "c9d1d9"}">${escapeHtml(l.name)}</span>`,
    )
    .join(" ");
  const body = (data.body || "").trim() || "_(no description)_";
  detail.innerHTML = `
        <div class="detail-meta">
            ${labels || ""}
            <span class="detail-meta-item">💬 ${data.comments?.length ?? 0}</span>
            <span class="detail-meta-item">created ${fmtDate(data.createdAt)}</span>
            <a class="detail-link" href="${escapeHtml(url)}" target="_blank">open on github →</a>
        </div>
        <div class="detail-body">${renderMarkdownLite(body)}</div>
    `;
  detail.hidden = false;
}

function fmtDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}

function renderMarkdownLite(md) {
  let s = escapeHtml(md);
  s = s.replace(/```([\s\S]*?)```/g, (_, code) => `<pre>${code}</pre>`);
  s = s.replace(/`([^`\n]+)`/g, "<code>$1</code>");
  s = s.replace(/^### (.+)$/gm, "<h4>$1</h4>");
  s = s.replace(/^## (.+)$/gm, "<h3>$1</h3>");
  s = s.replace(/^# (.+)$/gm, "<h2>$1</h2>");
  s = s.replace(/^- \[ \] (.+)$/gm, '<div class="task">☐ $1</div>');
  s = s.replace(/^- \[x\] (.+)$/gim, '<div class="task done">☑ $1</div>');
  s = s.replace(/^[-*] (.+)$/gm, "<li>$1</li>");
  s = s.replace(/(<li>.*?<\/li>(?:\n|$))+/g, (m) => `<ul>${m}</ul>`);
  s = s.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(?<!\*)\*([^*\n]+)\*(?!\*)/g, "<em>$1</em>");
  s = s.replace(/\n{2,}/g, "</p><p>");
  return `<p>${s}</p>`;
}
