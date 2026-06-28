export function renderHtml() {
  return `<!doctype html><html><head><meta charset="utf-8"/><title>Ralph Pipeline</title>
<style>
:root{--p0:var(--true-color-red,#cf222e);--ok:var(--true-color-green,#1a7f37);--run:var(--true-color-blue,#0969da);--warn:var(--true-color-orange,#bc4c00)}
*{box-sizing:border-box}
body{margin:0;background:var(--background-color-default,#0d1117);color:var(--text-color-default,#e6edf3);font-family:var(--font-sans,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif);font-size:13px;line-height:1.45}
header{position:sticky;top:0;background:var(--background-color-default,#0d1117);border-bottom:1px solid var(--border-color-default,#30363d);padding:8px 12px;z-index:5}
.htop{display:flex;align-items:center;gap:10px}
header h1{font-size:14px;margin:0;font-weight:var(--font-weight-semibold,600);white-space:nowrap}
.spacer{flex:1}.meta{font-size:11px;color:var(--text-color-muted,#8b949e);white-space:nowrap}.meta.stale{color:var(--warn)}
button{font:inherit;cursor:pointer;background:var(--button-default-bg,#21262d);color:inherit;border:1px solid var(--border-color-default,#30363d);border-radius:6px;padding:4px 10px}
button:hover{border-color:var(--color-focus-outline,#388bfd)}
.tabs{display:flex;gap:6px;margin-top:8px;flex-wrap:wrap}
.tab{font-size:11.5px;padding:3px 10px;border-radius:14px;border:1px solid var(--border-color-default,#30363d);background:var(--background-color-muted,#161b22);color:var(--text-color-muted,#8b949e);cursor:pointer}
.tab.active{color:var(--text-color-default,#e6edf3);border-color:var(--color-focus-outline,#388bfd);background:var(--background-color-default,#0d1117)}
main{padding:10px 12px 40px}
.banner{border:1px solid var(--border-color-default,#30363d);border-radius:8px;padding:10px 12px;margin-bottom:12px;background:var(--background-color-muted,#161b22)}
.banner.attn{border-color:var(--p0);background:color-mix(in srgb,var(--p0) 14%,transparent)}
.banner .q{font-size:13px;font-weight:600}.banner .sub{font-size:11px;color:var(--text-color-muted,#8b949e);margin-top:3px}
section{margin:12px 0 6px}
.sec-h{display:flex;align-items:center;gap:8px;margin-bottom:6px;font-weight:600;font-size:12px;letter-spacing:.02em;cursor:pointer;user-select:none}
.sec-h .cnt{display:inline-flex;align-items:center;justify-content:center;min-width:18px;height:18px;padding:0 5px;border-radius:9px;background:var(--background-color-muted,#161b22);border:1px solid var(--border-color-default,#30363d);color:var(--text-color-muted,#8b949e);font-weight:600;font-size:10.5px}
.sec-h .car{color:var(--text-color-muted,#8b949e);font-size:10px;width:10px;transition:transform .12s}.sec-h.collapsed .car{transform:rotate(-90deg)}.sec-body.hidden{display:none}
.card{border:1px solid var(--border-color-default,#30363d);border-radius:8px;padding:8px 10px;margin-bottom:6px;background:var(--background-color-muted,#161b22);display:block;text-decoration:none;color:inherit}
.card:hover{border-color:var(--color-focus-outline,#388bfd)}.card.next{border-left:3px solid var(--run)}.card.running{border-left:3px solid var(--ok)}.card.fail{border-left:3px solid var(--p0)}
.row1{display:flex;align-items:baseline;gap:6px}.num{font-family:var(--font-mono,monospace);color:var(--text-color-muted,#8b949e);font-size:11px}.ttl{flex:1;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.age{font-size:10px;color:var(--text-color-muted,#8b949e);white-space:nowrap}
.chips{margin-top:5px;display:flex;flex-wrap:wrap;gap:4px;align-items:center}.chip{font-size:10px;padding:1px 6px;border-radius:10px;border:1px solid var(--border-color-default,#30363d);color:var(--text-color-muted,#8b949e)}
.chip.p0,.chip.p1,.chip.fail{color:#ff9d9d;border-color:#7d2a2a}.chip.run{color:#a6d4ff;border-color:#1f4e7a}.chip.q{color:#aee5c0;border-color:#1f5e34}.chip.lane{color:#d8c4ff;border-color:#4b3a78}
.pr{font-size:10px;color:#a6d4ff;text-decoration:none}.pr:hover{text-decoration:underline}
.note{font-size:10.5px;color:var(--text-color-muted,#8b949e);margin-top:4px}.note.fail{color:#ffb4b4}.note code{font-family:var(--font-mono,monospace);font-size:10px}
.empty{font-size:11px;color:var(--text-color-muted,#8b949e);padding:2px 2px 6px;font-style:italic}
.err{border:1px solid #7d2a2a;background:#2a1414;color:#ffb4b4;border-radius:8px;padding:10px 12px;margin-bottom:10px;font-size:12px}.err b{color:#ffd0d0}.err .fix{display:block;margin-top:5px;font-size:11px;color:#ff9d9d}
.spin{display:inline-block;width:11px;height:11px;border:2px solid var(--text-color-muted,#8b949e);border-top-color:transparent;border-radius:50%;animation:sp .7s linear infinite;vertical-align:-1px}@keyframes sp{to{transform:rotate(360deg)}}
</style></head><body>
<header><div class="htop"><h1>Ralph Pipeline</h1><span class="spacer"></span><span class="meta" id="meta">loading...</span><button id="refresh">↻</button></div><div class="tabs" id="tabs"></div></header>
<main id="main"><div class="empty">Loading pipeline...</div></main>
<script>
const $=(s)=>document.querySelector(s);
let REPOS=[],CUR=null,LAST_OK=0;
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));}
function href(s){try{const u=new URL(String(s||""),"http://127.0.0.1");return (u.protocol==="http:"||u.protocol==="https:")?String(s):"#";}catch(e){return"#";}}
function chip(text,cls){return text?'<span class="chip '+(cls||"")+'">'+esc(text)+'</span>':"";}
function pcls(p){return p?("p"+(p.replace("priority:P",""))):"";}
function rel(iso){if(!iso)return"";const t=Date.parse(iso);if(isNaN(t))return"";let s=Math.max(0,(Date.now()-t)/1000);if(s<60)return Math.floor(s)+"s";if(s<3600)return Math.floor(s/60)+"m";if(s<86400)return Math.floor(s/3600)+"h";return Math.floor(s/86400)+"d";}
function ageTxt(d){return d==null?"":(d===0?"today":d+"d old");}
function card(c,extraCls){
  const cls="card "+(extraCls||"")+(c.queued?" next":"");
  let chips="";
  chips+=chip(c.repoSlug,"");
  chips+=chip(c.priority&&c.priority.replace("priority:",""),pcls(c.priority));
  chips+=chip(c.workType&&c.workType.replace("work:",""),"");
  chips+=chip(c.state&&c.state.replace("ralph:",""),c.state==="ralph:failed"?"fail":(c.state==="ralph:running"?"run":(c.queued?"q":"")));
  if(c.lane)chips+=chip(c.lane,"lane");
  if(c.runId)chips+=chip("run "+c.runId,"fail");
  if(c.assignee)chips+=chip("@"+c.assignee,"");
  if(c.linkedPR)chips+='<a class="pr" href="'+esc(href(c.linkedPR.url))+'" target="_blank" rel="noopener">PR #'+c.linkedPR.number+'</a>';
  let note="";
  if(c.reason)note='<div class="note">⏸ '+esc(c.reason)+'</div>';
  if(c.note)note='<div class="note">'+esc(c.note)+'</div>';
  if(c.worker&&c.worker.startedAt){
    note='<div class="note">⏱ running '+rel(c.worker.startedAt)+(c.worker.pid?' · pid '+esc(c.worker.pid):'')+(c.worker.resumeAttempt?' · resume '+c.worker.resumeAttempt:'')+(c.worker.logFile?' · <code>'+esc(c.worker.logFile)+'</code>':'')+'</div>';
  } else if(c.worker===null&&extraCls==="running"){
    note='<div class="note">⏱ claimed (no live worker record)</div>';
  }
  if(extraCls==="fail"){
    const when=c.failedAt||c.startedAt||c.runCreatedAt;
    note='<div class="note fail">Needs attention: '+esc(c.reason||"Ralph worker failed")+'</div>'+
      '<div class="note">'+(when?('failed '+rel(when)+' ago'):"failed")+
      (c.runDir?' · runDir <code>'+esc(c.runDir)+'</code>':'')+
      (c.logFilePath?' · log <code>'+esc(c.logFilePath)+'</code>':(c.logFile?' · log <code>'+esc(c.logFile)+'</code>':''))+'</div>';
  }
  const age=ageTxt(c.ageDays);
  return '<a class="'+cls+'" href="'+esc(href(c.url))+'" target="_blank" rel="noopener">'+
    '<div class="row1"><span class="num">#'+c.number+'</span><span class="ttl">'+esc(c.title)+'</span>'+(age?'<span class="age">'+age+'</span>':'')+'</div>'+
    (chips?'<div class="chips">'+chips+'</div>':"")+note+'</a>';
}
function collapsed(key){try{return localStorage.getItem("rp.col."+key)==="1";}catch(e){return false;}}
function setCollapsed(key,v){try{localStorage.setItem("rp.col."+key,v?"1":"0");}catch(e){}}
function section(key,icon,title,arr,extraCls,emptyMsg){
  const col=collapsed(key);
  let h='<section data-k="'+key+'"><div class="sec-h'+(col?' collapsed':'')+'" data-k="'+key+'"><span class="car">▾</span>'+icon+' '+esc(title)+' <span class="cnt">'+arr.length+'</span></div><div class="sec-body'+(col?' hidden':'')+'">';
  if(!arr.length)h+='<div class="empty">'+esc(emptyMsg||"none")+'</div>'; else h+=arr.map(c=>card(c,extraCls)).join("");
  return h+'</div></section>';
}
function render(d){
  let html="";
  if(d.error){
    const k=d.error.kind;const fix=k==="missing"?"Install GitHub CLI: https://cli.github.com":k==="auth"?"Run <code>gh auth login</code> in a terminal, then refresh.":"";
    html+='<div class="err"><b>'+(k==="missing"?"GitHub CLI not found":k==="auth"?"Not authenticated":"Couldn\\'t load issues")+'</b><br/>'+esc(d.error.message)+(fix?'<span class="fix">'+fix+'</span>':'')+'</div>';
  }
  const qtxt=d.nextQueue.length?d.nextQueue.map(n=>"#"+n).join(", "):"nothing eligible";
  const failed=d.failed||[];
  html+='<div class="banner'+(failed.length?' attn':'')+'"><div class="q">⏭️ Next orchestrator tick launches: '+esc(qtxt)+' <span class="meta">('+d.nextQueue.length+'/'+d.queueCap+', priority-first)</span></div>';
  let sub="";
  if(failed.length)sub+="🚨 Needs attention: "+failed.map(c=>"#"+c.number).join(", ")+". ";
  if(d.running.length)sub+="⚙️ Running now: "+d.running.map(c=>"#"+c.number).join(", ")+". ";
  if(d.lastTick){sub+="Last tick: "+esc(d.lastTick.outcome);if(d.lastTick.blockerCount)sub+=" ("+d.lastTick.blockerCount+" blocker"+(d.lastTick.blockerCount>1?"s":"")+")";if(d.lastTick.updatedAt)sub+=" · "+rel(d.lastTick.updatedAt)+" ago";}
  if(sub)html+='<div class="sub">'+sub+'</div>';
  html+='</div>';
  html+=section("failed","🚨","Failed · needs attention",d.failed||[],"fail","no failed work");
  html+=section("running","⚙️","Running",d.running,"running","no active workers");
  html+=section("ready","⏭️","Ready · next run",d.ready,"","no ready work");
  html+=section("deferred","⏸️","Ready · deferred",d.deferred,"","none deferred");
  html+=section("awaiting","🕹️","Awaiting promotion",d.awaiting,"","none");
  html+=section("held","⛔","Blocked · HITL",d.held||[],"","none");
  html+=section("triage","🧹","Needs triage",d.needsTriage,"","inbox clear");
  html+=section("recent","✅","Recently completed",d.recent.map(r=>({number:r.number,title:r.title,url:r.url,state:"ralph:"+r.outcome,ageDays:null,repoSlug:d.repoSlug})),"","nothing yet");
  $("#main").innerHTML=html;
  document.querySelectorAll('.sec-h').forEach(h=>{h.onclick=()=>{const k=h.getAttribute("data-k");const body=h.nextElementSibling;const now=!h.classList.contains("collapsed");h.classList.toggle("collapsed",now);body.classList.toggle("hidden",now);setCollapsed(k,now);};});
  LAST_OK=Date.now();updateMeta(d);
}
function updateMeta(d){const m=$("#meta");if(!LAST_OK){m.textContent="loading...";return;}const secs=Math.floor((Date.now()-LAST_OK)/1000);const ago=secs<2?"just now":secs<60?secs+"s ago":Math.floor(secs/60)+"m ago";m.textContent=(d?d.repoSlug+" · ":"")+"updated "+ago;m.classList.toggle("stale",secs>45);}
function renderTabs(){$("#tabs").innerHTML=REPOS.map(r=>'<span class="tab'+(r.slug===CUR?' active':'')+'" data-slug="'+esc(r.slug)+'">'+esc(r.label)+'</span>').join("");document.querySelectorAll('.tab').forEach(t=>{t.onclick=()=>{CUR=t.getAttribute("data-slug");renderTabs();load(true);};});}
async function load(showLoading){if(showLoading)$("#main").innerHTML='<div class="empty"><span class="spin"></span> Loading...</div>';try{const r=await fetch("/state?repo="+encodeURIComponent(CUR||""));const d=await r.json();render(d);}catch(e){$("#main").innerHTML='<div class="err"><b>Panel error</b><br/>'+esc(e)+'</div>';}}
$("#refresh").onclick=async()=>{const b=$("#refresh");b.innerHTML='<span class="spin"></span>';try{await fetch("/refresh?repo="+encodeURIComponent(CUR||""),{method:"POST"});await load();}finally{b.textContent="↻";}};
async function boot(){try{const r=await fetch("/repos");REPOS=await r.json();}catch(e){REPOS=[];}CUR=REPOS[0]?REPOS[0].slug:"";renderTabs();await load(true);try{const ev=new EventSource("/events");ev.onmessage=()=>load();}catch(e){}setInterval(load,20000);setInterval(()=>updateMeta(null),1000);}
boot();
</script></body></html>`;
}
