// Renderer for the Ralph dashboard canvas with two tabs: Loop and Pipeline
// Returns a self-contained HTML document with tabbed navigation.

export function pageHtml() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Ralph Dashboard</title>
<style>
:root{
  --bg:var(--background-color-default,#0d1117);--bg-muted:var(--background-color-muted,rgba(255,255,255,0.03));
  --border:var(--border-color-default,#30363d);--fg:var(--text-color-default,#e6edf3);
  --muted:var(--text-color-muted,#8b949e);--green:var(--true-color-green,#3fb950);
  --green-muted:var(--true-color-green-muted,rgba(63,185,80,0.15));--red:var(--true-color-red,#f85149);
  --red-muted:var(--true-color-red-muted,rgba(248,81,73,0.15));--blue:var(--true-color-blue,#58a6ff);
  --blue-muted:var(--true-color-blue-muted,rgba(88,166,255,0.15));--yellow:var(--true-color-yellow,#d29922);
  --yellow-muted:var(--true-color-yellow-muted,rgba(210,153,34,0.15));--purple:var(--true-color-purple,#a371f7);
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--font-sans,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif);font-size:13px;line-height:1.5}
.wrap{padding:14px 16px 40px;max-width:880px;margin:0 auto}
header.top{display:flex;align-items:center;gap:10px;padding-bottom:10px;border-bottom:1px solid var(--border);margin-bottom:0;position:sticky;top:0;background:var(--bg);z-index:5}
header.top h1{font-size:16px;font-weight:600;margin:0;flex:0 0 auto}
.prd{color:var(--muted);font-size:12px;flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.badge{font-size:11px;font-weight:600;padding:2px 9px;border-radius:999px;border:1px solid transparent;white-space:nowrap}
.badge.run{color:var(--green);background:var(--green-muted);border-color:var(--green)}
.badge.idle{color:var(--muted);background:var(--bg-muted);border-color:var(--border)}
.badge.err{color:var(--red);background:var(--red-muted);border-color:var(--red)}
button.refresh{font:inherit;font-size:12px;color:var(--fg);background:var(--bg-muted);border:1px solid var(--border);border-radius:6px;padding:3px 10px;cursor:pointer}
button.refresh:hover{border-color:var(--blue)}
.tabs{display:flex;gap:0;margin-top:10px;border-bottom:1px solid var(--border)}
.tab{padding:8px 16px;font-size:13px;font-weight:500;cursor:pointer;background:transparent;border:none;border-bottom:2px solid transparent;color:var(--muted);transition:all .15s}
.tab:hover{color:var(--fg)}
.tab.active{color:var(--fg);border-bottom-color:var(--blue)}
.tab-content{display:none;padding-top:14px}
.tab-content.active{display:block}
section{margin-bottom:16px}
h2{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 7px;font-weight:600}
.stats{display:flex;flex-wrap:wrap;gap:14px}
.stat{background:var(--bg-muted);border:1px solid var(--border);border-radius:8px;padding:8px 12px;min-width:92px}
.stat .n{font-size:18px;font-weight:600}
.stat .l{font-size:11px;color:var(--muted)}
.card{background:var(--bg-muted);border:1px solid var(--border);border-radius:8px;padding:9px 11px;margin-bottom:7px;text-decoration:none;color:inherit;display:block}
.card:hover{border-color:var(--blue)}
.row{display:flex;align-items:baseline;gap:8px}
.row .num{color:var(--blue);font-weight:600;font-family:var(--font-mono,monospace);flex:0 0 auto}
.row .title{flex:1 1 auto;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .meta{color:var(--muted);font-size:11px;flex:0 0 auto}
.tags{display:inline-flex;gap:5px;margin-left:4px}
.tag{font-size:10px;padding:0 6px;border-radius:999px;border:1px solid var(--border);color:var(--muted)}
.tag.hitl{color:var(--yellow);border-color:var(--yellow);background:var(--yellow-muted)}
.tag.afk{color:var(--green);border-color:var(--green);background:var(--green-muted)}
.pill{font-size:10px;font-weight:600;padding:1px 7px;border-radius:999px}
.pill.merged{color:var(--blue);background:var(--blue-muted)}
.pill.open{color:var(--green);background:var(--green-muted)}
.pill.closed{color:var(--muted);background:var(--bg-muted)}
.worker{border-left:3px solid var(--green)}
.worker .stage{color:var(--green);font-size:12px}
a{color:var(--blue);text-decoration:none}
a:hover{text-decoration:underline}
.empty{color:var(--muted);font-size:12px;font-style:italic}
pre.tail{background:var(--bg-muted);border:1px solid var(--border);border-radius:8px;padding:9px 11px;overflow-x:auto;font-family:var(--font-mono,monospace);font-size:11px;line-height:1.45;color:var(--muted);max-height:220px;margin:0}
details>summary{cursor:pointer;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em;font-weight:600;margin-bottom:7px}
.banner{border:1px solid var(--yellow);background:var(--yellow-muted);color:var(--fg);border-radius:8px;padding:9px 11px;font-size:12px;margin-bottom:14px}
.banner code{font-family:var(--font-mono,monospace)}
.pipe-banner{border:1px solid var(--border);background:var(--bg-muted);border-radius:8px;padding:10px 12px;margin-bottom:14px}
.pipe-banner .q{font-size:13px;font-weight:600}
.pipe-banner .sub{font-size:11px;color:var(--muted);margin-top:3px}
.sec-h{display:flex;align-items:center;gap:8px;margin-bottom:6px;font-weight:600;font-size:12px;letter-spacing:.02em;cursor:pointer;user-select:none}
.sec-h .cnt{display:inline-flex;align-items:center;justify-content:center;min-width:18px;height:18px;padding:0 5px;border-radius:9px;background:var(--bg-muted);border:1px solid var(--border);color:var(--muted);font-weight:600;font-size:10.5px}
.sec-h .car{color:var(--muted);font-size:10px;width:10px;transition:transform .12s}
.sec-h.collapsed .car{transform:rotate(-90deg)}
.sec-body.hidden{display:none}
.card.next{border-left:3px solid var(--blue)}
.card.running{border-left:3px solid var(--green)}
.card.fail{border-left:3px solid var(--red)}
.chips{margin-top:5px;display:flex;flex-wrap:wrap;gap:4px;align-items:center}
.chip{font-size:10px;padding:1px 6px;border-radius:10px;border:1px solid var(--border);color:var(--muted)}
.chip.p0,.chip.p1{color:#ff9d9d;border-color:#7d2a2a}
.chip.run{color:#a6d4ff;border-color:#1f4e7a}
.chip.q{color:#aee5c0;border-color:#1f5e34}
.chip.lane{color:#d8c4ff;border-color:#4b3a78}
.pr-link{font-size:10px;color:#a6d4ff;text-decoration:none}
.pr-link:hover{text-decoration:underline}
.note{font-size:10.5px;color:var(--muted);margin-top:4px}
.err-box{border:1px solid #7d2a2a;background:#2a1414;color:#ffb4b4;border-radius:8px;padding:10px 12px;margin-bottom:10px;font-size:12px}
.err-box b{color:#ffd0d0}
.err-box .fix{display:block;margin-top:5px;font-size:11px;color:#ff9d9d}
.updated{color:var(--muted);font-size:11px;margin-top:10px}
</style>
</head>
<body>
<div class="wrap">
<header class="top">
<h1>Ralph Dashboard</h1>
<span class="prd" id="prd">Loading…</span>
<span class="badge idle" id="state">…</span>
<button class="refresh" id="refreshBtn">Refresh</button>
</header>
<div class="tabs">
<button class="tab active" data-tab="loop">Loop</button>
<button class="tab" data-tab="pipeline">Pipeline</button>
</div>
<div class="tab-content active" id="content-loop"></div>
<div class="tab-content" id="content-pipeline"></div>
<div class="updated" id="updated"></div>
</div>
<script>
var REPO="",CUR="loop",LOOP=null,PIPE=null,ILOOP=false,IPIPE=false;
function e(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function tag(l){var o="";(l||[]).forEach(function(t){var c=t==="hitl"?"tag hitl":(t==="ready-for-agent"?"tag afk":"tag");var x=t==="ready-for-agent"?"AFK":t;o+='<span class="'+c+'">'+e(x)+'</span>';});return o?'<span class="tags">'+o+'</span>':"";}
function rLoop(d){var h="";if(d.error){h+='<div class="banner">Could not read Ralph status: <code>'+e(d.error)+'</code>. Make sure the repo has a <code>.ralph/</code> dir.</div>';return h;}if(!d.loopRunning){h+='<div class="banner">Loop is <strong>idle</strong>. Start it with <code>./.ralph/launch.sh</code> or from the Ralph Dashboard window.</div>';}var c=d.cumulative||{};h+='<section><h2>Today</h2><div class="stats">'+'<div class="stat"><div class="n">'+(c.mergedToday||0)+'</div><div class="l">PRs merged</div></div>'+'<div class="stat"><div class="n" style="color:var(--green)">+'+(c.additions||0)+'</div><div class="l">additions</div></div>'+'<div class="stat"><div class="n" style="color:var(--red)">-'+(c.deletions||0)+'</div><div class="l">deletions</div></div>'+'<div class="stat"><div class="n">'+(c.changedFiles||0)+'</div><div class="l">files</div></div>'+'</div></section>';var w=(d.workers||[]).filter(function(x){return x&&(x.issue||x.workerId);});h+='<section><h2>Active workers ('+w.length+')</h2>';if(!w.length)h+='<div class="empty">No workers running.</div>';w.forEach(function(x){var s=x.stageLabel||x.label||(x.stage&&x.stage.label)||"working";var i=x.stageIcon||x.icon||(x.stage&&x.stage.icon)||"⚙";var p=x.currentPr;h+='<div class="card worker"><div class="row">'+'<span class="num">#'+e(x.issue||"?")+'</span>'+'<span class="title">'+e(x.issueTitle||x.title||"")+'</span>'+'<span class="stage">'+e(i)+' '+e(s)+'</span></div>';if(p&&p.number){h+='<div class="row" style="margin-top:4px"><span class="meta">PR <a href="'+e(p.url)+'" target="_blank">#'+e(p.number)+'</a> '+e(p.state||"")+(p.isDraft?" (draft)":"")+(p.checks?" · checks "+p.checks.pass+"/"+p.checks.total:"")+'</span></div>';}h+='</div>';});h+='</section>';var sl=d.openSlices||[];h+='<section><h2>Queue ('+sl.length+' open slices)</h2>';if(!sl.length)h+='<div class="empty">No open slices.</div>';sl.forEach(function(s){h+='<div class="card"><div class="row">'+'<span class="num"><a href="'+e(s.url)+'" target="_blank">#'+e(s.number)+'</a></span>'+'<span class="title">'+e(s.title)+tag(s.labels)+'</span></div></div>';});h+='</section>';var pr=d.recentPrs||[];h+='<section><h2>Recent PRs</h2>';if(!pr.length)h+='<div class="empty">No PRs yet.</div>';pr.slice(0,8).forEach(function(p){var cl=p.state==="MERGED"?"merged":(p.state==="OPEN"?"open":"closed");h+='<div class="card"><div class="row">'+'<span class="num"><a href="'+e(p.url)+'" target="_blank">#'+e(p.number)+'</a></span>'+'<span class="title">'+e(p.title)+'</span>'+'<span class="pill '+cl+'">'+e(p.state||"")+'</span>'+'<span class="meta">+'+(p.additions||0)+'/-'+(p.deletions||0)+'</span></div></div>';});h+='</section>';if(d.loopOutTail){h+='<section><details><summary>loop.out (tail)</summary><pre class="tail">'+e(d.loopOutTail)+'</pre></details></section>';}return h;}
function rPipe(d){var h="";if(!d||!d.nextQueue){h+='<div class="empty">Loading pipeline…</div>';return h;}if(d.error){var k=d.error.kind;var f=k==="missing"?"Install GitHub CLI: https://cli.github.com":(k==="auth"?"Run <code>gh auth login</code> in a terminal, then refresh.":"");h+='<div class="err-box"><b>'+(k==="missing"?"GitHub CLI not found":(k==="auth"?"Not authenticated":"Couldn't load issues"))+'</b><br/>'+e(d.error.message)+(f?'<span class="fix">'+f+'</span>':'')+'</div>';return h;}var q=d.nextQueue.length?d.nextQueue.map(function(n){return"#"+n;}).join(", "):"nothing eligible";h+='<div class="pipe-banner"><div class="q">⏭️ Next orchestrator tick launches: '+e(q)+' <span class="meta">('+d.nextQueue.length+'/'+d.queueCap+', priority-first)</span></div>';var s="";if((d.running||[]).length)s="⚙️ Running now: "+d.running.map(function(c){return"#"+c.number;}).join(", ")+". ";if(d.lastTick){s+="Last tick: "+e(d.lastTick.outcome);if(d.lastTick.blockerCount)s+=" ("+d.lastTick.blockerCount+" blocker"+(d.lastTick.blockerCount>1?"s":"")+")";if(d.lastTick.updatedAt)s+=" · "+rel(d.lastTick.updatedAt)+" ago";}if(s)h+='<div class="sub">'+s+'</div>';h+='</div>';h+=sec("running","⚙️","Running",d.running||[],"running","no active workers");h+=sec("ready","⏭️","Ready · next run",d.ready||[],"","no ready work");h+=sec("deferred","⏸️","Ready · deferred",d.deferred||[],"","none deferred");h+=sec("awaiting","🕹️","Awaiting promotion",d.awaiting||[],"","none");h+=sec("held","⛔","Blocked · HITL",d.held||[],"","none");h+=sec("triage","🧹","Needs triage",d.needsTriage||[],"","inbox clear");h+=sec("recent","✅","Recently completed",(d.recent||[]).map(function(r){return{number:r.number,title:r.title,url:r.url,state:"ralph:"+r.outcome,ageDays:null};}),"","nothing yet");return h;}
function sec(k,i,t,a,x,em){var co=col(k);var h='<section data-k="'+k+'"><div class="sec-h'+(co?' collapsed':'')+'" data-k="'+k+'">'+'<span class="car">▾</span>'+i+' '+e(t)+' <span class="cnt">'+a.length+'</span></div>'+'<div class="sec-body'+(co?' hidden':'')+'">';if(!a.length)h+='<div class="empty">'+e(em||"none")+'</div>';else h+=a.map(function(c){return cd(c,x);}).join("");return h+'</div></section>';}
function cd(c,x){var cl="card "+(x||"")+(c.queued?" next":"");var ch="";ch+=chip(c.priority&&c.priority.replace("priority:",""),pcl(c.priority));ch+=chip(c.workType&&c.workType.replace("work:",""),"");ch+=chip(c.state&&c.state.replace("ralph:",""),c.state==="ralph:running"?"run":(c.queued?"q":""));if(c.lane)ch+=chip(c.lane,"lane");if(c.assignee)ch+=chip("@"+c.assignee,"");if(c.linkedPR)ch+='<a class="pr-link" href="'+e(c.linkedPR.url)+'" target="_blank" rel="noopener">PR #'+c.linkedPR.number+'</a>';var n="";if(c.reason)n='<div class="note">⏸ '+e(c.reason)+'</div>';if(c.note)n='<div class="note">'+e(c.note)+'</div>';if(c.worker&&c.worker.startedAt){n='<div class="note">⏱ running '+rel(c.worker.startedAt)+(c.worker.pid?' · pid '+e(c.worker.pid):'')+(c.worker.resumeAttempt?' · resume '+c.worker.resumeAttempt:'')+(c.worker.logFile?' · <code>'+e(c.worker.logFile)+'</code>':'')+'</div>';}else if(c.worker===null&&x==="running"){n='<div class="note">⏱ claimed (no live worker record)</div>';}var ag=age(c.ageDays);return'<a class="'+cl+'" href="'+e(c.url)+'" target="_blank" rel="noopener">'+'<div class="row"><span class="num">#'+c.number+'</span><span class="title">'+e(c.title)+'</span>'+(ag?'<span class="meta">'+ag+'</span>':'')+'</div>'+(ch?'<div class="chips">'+ch+'</div>':"")+n+'</a>';}
function chip(t,c){return t?'<span class="chip '+(c||"")+'">'+e(t)+'</span>':"";}
function pcl(p){return p?("p"+(p.replace("priority:P",""))):""; }
function rel(iso){if(!iso)return"";var t=Date.parse(iso);if(isNaN(t))return"";var s=Math.max(0,(Date.now()-t)/1000);if(s<60)return Math.floor(s)+"s";if(s<3600)return Math.floor(s/60)+"m";if(s<86400)return Math.floor(s/3600)+"h";return Math.floor(s/86400)+"d";}
function age(d){return d==null?"":(d===0?"today":d+"d old");}
function col(k){try{return localStorage.getItem("rp.col."+k)==="1";}catch(e){return false;}}
function scol(k,v){try{localStorage.setItem("rp.col."+k,v?"1":"0");}catch(e){}}
function render(){var le=document.getElementById("content-loop");var pe=document.getElementById("content-pipeline");var pr=document.getElementById("prd");var st=document.getElementById("state");if(CUR==="loop"){le.innerHTML=rLoop(LOOP||{});if(LOOP&&LOOP.error){st.className="badge err";st.textContent="error";pr.textContent=REPO||"";}else if(LOOP){pr.textContent=LOOP.headerText||(LOOP.config&&LOOP.config.repo)||"";pr.title=pr.textContent;if(LOOP.loopRunning){st.className="badge run";st.textContent="● running";}else{st.className="badge idle";st.textContent="idle";}}}else{pe.innerHTML=rPipe(PIPE||{});if(PIPE&&PIPE.error){st.className="badge err";st.textContent="error";}else if(PIPE){pr.textContent=PIPE.repoSlug||"";pr.title=pr.textContent;st.className="badge idle";st.textContent="read-only";}}document.querySelectorAll('.sec-h').forEach(function(h){h.onclick=function(){var k=h.getAttribute("data-k");var b=h.nextElementSibling;var now=!h.classList.contains("collapsed");h.classList.toggle("collapsed",now);b.classList.toggle("hidden",now);scol(k,now);};});document.querySelectorAll('.chip').forEach(function(ch){if(ch.textContent==="failed")ch.classList.add("p0");});}
function fLoop(){if(ILOOP)return;ILOOP=true;fetch("./status",{cache:"no-store"}).then(function(r){return r.json();}).then(function(d){REPO=(d&&d.config&&d.config.repo)||REPO;LOOP=d;if(CUR==="loop")render();document.getElementById("updated").textContent="Updated "+new Date().toLocaleTimeString();}).catch(function(e){LOOP={error:String(e&&e.message||e)};if(CUR==="loop")render();}).finally(function(){ILOOP=false;});}
function fPipe(){if(IPIPE)return;IPIPE=true;fetch("./pipeline-state",{cache:"no-store"}).then(function(r){return r.json();}).then(function(d){PIPE=d;if(CUR==="pipeline")render();document.getElementById("updated").textContent="Updated "+new Date().toLocaleTimeString();}).catch(function(e){PIPE={error:{kind:"other",message:String(e&&e.message||e)}};if(CUR==="pipeline")render();}).finally(function(){IPIPE=false;});}
function fAll(){if(CUR==="loop")fLoop();else fPipe();}
document.querySelectorAll('.tab').forEach(function(tab){tab.onclick=function(){var t=tab.getAttribute("data-tab");CUR=t;document.querySelectorAll('.tab').forEach(function(el){el.classList.remove("active");});document.querySelectorAll('.tab-content').forEach(function(el){el.classList.remove("active");});tab.classList.add("active");document.getElementById("content-"+t).classList.add("active");render();if(t==="loop"&&!LOOP)fLoop();if(t==="pipeline"&&!PIPE)fPipe();};});
document.getElementById("refreshBtn").addEventListener("click",fAll);
fLoop();
setInterval(fLoop,5000);
setInterval(fPipe,10000);
</script>
</body>
</html>`;
}
