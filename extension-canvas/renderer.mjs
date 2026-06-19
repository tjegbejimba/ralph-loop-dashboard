// Renderer for the Ralph dashboard canvas. Returns a self-contained HTML
// document that polls `/status` (served by the extension's loopback server)
// and renders a read-only view of the Ralph loop. Styled with the app's
// canvas theme tokens (with safe fallbacks) so it blends into the panel.

export function pageHtml() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Ralph Loop</title>
<style>
  :root {
    --bg: var(--background-color-default, #0d1117);
    --bg-muted: var(--background-color-muted, rgba(255,255,255,0.03));
    --border: var(--border-color-default, #30363d);
    --fg: var(--text-color-default, #e6edf3);
    --muted: var(--text-color-muted, #8b949e);
    --green: var(--true-color-green, #3fb950);
    --green-muted: var(--true-color-green-muted, rgba(63,185,80,0.15));
    --red: var(--true-color-red, #f85149);
    --red-muted: var(--true-color-red-muted, rgba(248,81,73,0.15));
    --blue: var(--true-color-blue, #58a6ff);
    --blue-muted: var(--true-color-blue-muted, rgba(88,166,255,0.15));
    --yellow: var(--true-color-yellow, #d29922);
    --yellow-muted: var(--true-color-yellow-muted, rgba(210,153,34,0.15));
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--fg);
    font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif);
    font-size: var(--text-body-medium, 13px);
    line-height: var(--leading-body-medium, 1.5);
  }
  .wrap { padding: 14px 16px 40px; max-width: 880px; margin: 0 auto; }
  header.top {
    display: flex; align-items: center; gap: 10px;
    padding-bottom: 10px; border-bottom: 1px solid var(--border); margin-bottom: 14px;
    position: sticky; top: 0; background: var(--bg); z-index: 5;
  }
  header.top h1 {
    font-size: var(--text-title-medium, 16px); font-weight: 600; margin: 0; flex: 0 0 auto;
  }
  .prd { color: var(--muted); font-size: 12px; flex: 1 1 auto; min-width: 0;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .badge { font-size: 11px; font-weight: 600; padding: 2px 9px; border-radius: 999px;
    border: 1px solid transparent; white-space: nowrap; }
  .badge.run { color: var(--green); background: var(--green-muted); border-color: var(--green); }
  .badge.idle { color: var(--muted); background: var(--bg-muted); border-color: var(--border); }
  .badge.err  { color: var(--red); background: var(--red-muted); border-color: var(--red); }
  .updated { color: var(--muted); font-size: 11px; }
  button.refresh {
    font: inherit; font-size: 12px; color: var(--fg); background: var(--bg-muted);
    border: 1px solid var(--border); border-radius: 6px; padding: 3px 10px; cursor: pointer;
  }
  button.refresh:hover { border-color: var(--blue); }
  section { margin-bottom: 16px; }
  h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted);
    margin: 0 0 7px; font-weight: 600; }
  .stats { display: flex; flex-wrap: wrap; gap: 14px; }
  .stat { background: var(--bg-muted); border: 1px solid var(--border); border-radius: 8px;
    padding: 8px 12px; min-width: 92px; }
  .stat .n { font-size: 18px; font-weight: 600; }
  .stat .l { font-size: 11px; color: var(--muted); }
  .card { background: var(--bg-muted); border: 1px solid var(--border); border-radius: 8px;
    padding: 9px 11px; margin-bottom: 7px; }
  .row { display: flex; align-items: baseline; gap: 8px; }
  .row .num { color: var(--blue); font-weight: 600; font-family: var(--font-mono, monospace);
    flex: 0 0 auto; }
  .row .title { flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .row .meta { color: var(--muted); font-size: 11px; flex: 0 0 auto; }
  .tags { display: inline-flex; gap: 5px; margin-left: 4px; }
  .tag { font-size: 10px; padding: 0 6px; border-radius: 999px; border: 1px solid var(--border);
    color: var(--muted); }
  .tag.hitl { color: var(--yellow); border-color: var(--yellow); background: var(--yellow-muted); }
  .tag.afk  { color: var(--green); border-color: var(--green); background: var(--green-muted); }
  .pill { font-size: 10px; font-weight: 600; padding: 1px 7px; border-radius: 999px; }
  .pill.merged { color: var(--blue); background: var(--blue-muted); }
  .pill.open   { color: var(--green); background: var(--green-muted); }
  .pill.closed { color: var(--muted); background: var(--bg-muted); }
  .worker { border-left: 3px solid var(--green); }
  .worker .stage { color: var(--green); font-size: 12px; }
  a { color: var(--blue); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .empty { color: var(--muted); font-size: 12px; font-style: italic; }
  pre.tail { background: var(--bg-muted); border: 1px solid var(--border); border-radius: 8px;
    padding: 9px 11px; overflow-x: auto; font-family: var(--font-mono, monospace);
    font-size: 11px; line-height: 1.45; color: var(--muted); max-height: 220px; margin: 0; }
  details > summary { cursor: pointer; color: var(--muted); font-size: 11px;
    text-transform: uppercase; letter-spacing: .06em; font-weight: 600; margin-bottom: 7px; }
  .banner { border: 1px solid var(--yellow); background: var(--yellow-muted); color: var(--fg);
    border-radius: 8px; padding: 9px 11px; font-size: 12px; margin-bottom: 14px; }
  .banner code { font-family: var(--font-mono, monospace); }
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <h1>Ralph Loop</h1>
    <span class="prd" id="prd">Loading…</span>
    <span class="badge idle" id="state">…</span>
    <button class="refresh" id="refreshBtn" title="Refresh now">Refresh</button>
  </header>
  <div id="content"></div>
  <div class="updated" id="updated"></div>
</div>
<script>
  var REPO_HINT = "";
  function esc(s){ return String(s==null?"":s).replace(/[&<>"']/g,function(c){
    return {"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;"}[c]; }); }

  function tagFor(labels){
    var out = "";
    (labels||[]).forEach(function(l){
      var cls = l === "hitl" ? "tag hitl" : (l === "ready-for-agent" ? "tag afk" : "tag");
      var txt = l === "ready-for-agent" ? "AFK" : l;
      out += '<span class="'+cls+'">'+esc(txt)+'</span>';
    });
    return out ? '<span class="tags">'+out+'</span>' : "";
  }

  function render(d){
    var prd = document.getElementById("prd");
    var state = document.getElementById("state");
    var content = document.getElementById("content");

    if (d.error){
      state.className = "badge err"; state.textContent = "error";
      prd.textContent = REPO_HINT || "";
      content.innerHTML = '<div class="banner">Could not read Ralph status: <code>'+esc(d.error)+
        '</code>. Make sure the repo has a <code>.ralph/</code> dir.</div>';
      return;
    }

    prd.textContent = d.headerText || (d.config && d.config.repo) || "";
    prd.title = prd.textContent;
    if (d.loopRunning){ state.className = "badge run"; state.textContent = "● running"; }
    else { state.className = "badge idle"; state.textContent = "idle"; }

    var html = "";

    if (!d.loopRunning){
      html += '<div class="banner">Loop is <strong>idle</strong>. Start it with '+
        '<code>cd '+esc((d.config&&d.config.repo)? "" : "")+'./.ralph &amp;&amp; ../.ralph/launch.sh</code> '+
        'or from the Ralph Dashboard window. Workers begin with the first unblocked slice.</div>';
    }

    // Cumulative stats
    var c = d.cumulative || {};
    html += '<section><h2>Today</h2><div class="stats">'+
      '<div class="stat"><div class="n">'+(c.mergedToday||0)+'</div><div class="l">PRs merged</div></div>'+
      '<div class="stat"><div class="n" style="color:var(--green)">+'+(c.additions||0)+'</div><div class="l">additions</div></div>'+
      '<div class="stat"><div class="n" style="color:var(--red)">-'+(c.deletions||0)+'</div><div class="l">deletions</div></div>'+
      '<div class="stat"><div class="n">'+(c.changedFiles||0)+'</div><div class="l">files</div></div>'+
      '</div></section>';

    // Active workers
    var workers = (d.workers||[]).filter(function(w){ return w && (w.issue || w.workerId); });
    html += '<section><h2>Active workers ('+workers.length+')</h2>';
    if (!workers.length){ html += '<div class="empty">No workers running.</div>'; }
    workers.forEach(function(w){
      var st = w.stageLabel || w.label || (w.stage && w.stage.label) || "working";
      var ic = w.stageIcon || w.icon || (w.stage && w.stage.icon) || "⚙";
      var pr = w.currentPr;
      html += '<div class="card worker"><div class="row">'+
        '<span class="num">#'+esc(w.issue||"?")+'</span>'+
        '<span class="title">'+esc(w.issueTitle||w.title||"")+'</span>'+
        '<span class="stage">'+esc(ic)+' '+esc(st)+'</span></div>';
      if (pr && pr.number){
        html += '<div class="row" style="margin-top:4px"><span class="meta">PR '+
          '<a href="'+esc(pr.url)+'" target="_blank">#'+esc(pr.number)+'</a> '+
          esc(pr.state||"")+(pr.isDraft?" (draft)":"")+
          (pr.checks?(" · checks "+pr.checks.pass+"/"+pr.checks.total):"")+'</span></div>';
      }
      html += '</div>';
    });
    html += '</section>';

    // Queue (open slices)
    var slices = d.openSlices || [];
    html += '<section><h2>Queue ('+slices.length+' open slices)</h2>';
    if (!slices.length){ html += '<div class="empty">No open slices match the queue search.</div>'; }
    slices.forEach(function(s){
      html += '<div class="card"><div class="row">'+
        '<span class="num"><a href="'+esc(s.url)+'" target="_blank">#'+esc(s.number)+'</a></span>'+
        '<span class="title">'+esc(s.title)+tagFor(s.labels)+'</span></div></div>';
    });
    html += '</section>';

    // Recent PRs
    var prs = d.recentPrs || [];
    html += '<section><h2>Recent PRs</h2>';
    if (!prs.length){ html += '<div class="empty">No PRs yet.</div>'; }
    prs.slice(0,8).forEach(function(p){
      var cls = p.state === "MERGED" ? "merged" : (p.state === "OPEN" ? "open" : "closed");
      html += '<div class="card"><div class="row">'+
        '<span class="num"><a href="'+esc(p.url)+'" target="_blank">#'+esc(p.number)+'</a></span>'+
        '<span class="title">'+esc(p.title)+'</span>'+
        '<span class="pill '+cls+'">'+esc(p.state||"")+'</span>'+
        '<span class="meta">+'+(p.additions||0)+'/-'+(p.deletions||0)+'</span></div></div>';
    });
    html += '</section>';

    // loop.out tail
    if (d.loopOutTail){
      html += '<section><details><summary>loop.out (tail)</summary>'+
        '<pre class="tail">'+esc(d.loopOutTail)+'</pre></details></section>';
    }

    content.innerHTML = html;
  }

  var inflight = false;
  function refresh(){
    if (inflight) return;
    inflight = true;
    fetch("./status", { cache: "no-store" })
      .then(function(r){ return r.json(); })
      .then(function(d){
        REPO_HINT = (d && d.config && d.config.repo) || REPO_HINT;
        render(d);
        document.getElementById("updated").textContent =
          "Updated " + new Date().toLocaleTimeString();
      })
      .catch(function(e){ render({ error: String(e && e.message || e) }); })
      .finally(function(){ inflight = false; });
  }

  document.getElementById("refreshBtn").addEventListener("click", refresh);
  refresh();
  setInterval(refresh, 5000);
</script>
</body>
</html>`;
}
