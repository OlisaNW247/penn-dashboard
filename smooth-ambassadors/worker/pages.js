// Page rendering for ambassadors (/a/{token}) and founders (/f/{secret}).
import { SCHOOLS, CHANNELS, designsFor, posterImagePath, posterName, scanKey } from "./catalog.js";
import { layout, esc, attr } from "./html.js";
import { isPhone, phoneForSms, IDEA_TOTAL_LIMIT } from "./data.js";
import { ambassadorLinks, digestText, welcomeText, momentTexts, moments, firstName } from "./digest.js";
import messages from "./templates/messages.json";

function fillMsg(text, vars) {
  return text.replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? `{${k}}`);
}

function channelName(k) {
  return Object.hasOwn(CHANNELS, k) ? CHANNELS[k] : k;
}

// JSON inlined in a <script>: "<" is escaped so a name holding </script> (or
// <!--) cannot end the block early.
function scriptJSON(v) {
  return JSON.stringify(v).replace(/</g, "\\u003c");
}

function ago(ts) {
  if (!ts) return "never";
  const d = (Date.now() - new Date(ts).getTime()) / 86400000;
  if (d < 1) return "today";
  if (d < 2) return "yesterday";
  return `${Math.floor(d)}d ago`;
}

function smsLink(contact, body) {
  if (!isPhone(contact)) return null;
  return `sms:${phoneForSms(contact)}&body=${encodeURIComponent(body)}`;
}

function sendButton(contact, body, label = "text it") {
  const sms = smsLink(contact, body);
  const copy = `<button class="small ghost" data-copy="${attr(body)}">copy</button>`;
  return sms ? `<a class="btn small" href="${attr(sms)}">${esc(label)}</a> ${copy}` : copy;
}

// ---------------------------------------------------------------- ambassador

// Small decorative glyphs for the three doors. Drawn here, not fetched.
const ICON_POSTERS = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="3" width="8" height="8" rx="2.5" fill="currentColor"/><rect x="13" y="3" width="8" height="8" rx="2.5" fill="currentColor"/><rect x="3" y="13" width="8" height="8" rx="2.5" fill="currentColor"/><rect x="13" y="13" width="8" height="8" rx="2.5" fill="currentColor"/></svg>`;
const ICON_DASH = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="12" width="5" height="9" rx="2" fill="currentColor"/><rect x="9.5" y="3" width="5" height="18" rx="2" fill="currentColor"/><rect x="16" y="8" width="5" height="13" rx="2" fill="currentColor"/></svg>`;
const ICON_IDEA = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v18M3 12h18" stroke="currentColor" stroke-width="4.5" stroke-linecap="round"/></svg>`;

// The client half of "send a poster idea": shrink the picture on a canvas,
// then post JSON. Plain ES2017, no libraries. The server checks everything
// again, so none of this is trusted.
const IDEA_JS = String.raw`
(function(){
var f=document.getElementById('ideaForm');if(!f)return;
var file=document.getElementById('ideaFile'),prev=document.getElementById('ideaPreview'),msg=document.getElementById('ideaMsg'),
btn=document.getElementById('ideaSend'),cnt=document.getElementById('ideaCount'),fname=document.getElementById('ideaFileName'),note=document.getElementById('ideaNote');
var blob=null,sent=IDEA.sent;
function say(t,bad){msg.textContent=t;msg.className='small'+(bad?' err':'')}
function count(){cnt.textContent=sent+' of '+IDEA.limit+' sent'}
function load(fl){return new Promise(function(res,rej){var u=URL.createObjectURL(fl),im=new Image();im.onload=function(){URL.revokeObjectURL(u);res(im)};im.onerror=function(){URL.revokeObjectURL(u);rej(new Error('bad'))};im.src=u})}
function toBlob(c,q){return new Promise(function(r){c.toBlob(r,'image/jpeg',q)})}
function b64(b){return new Promise(function(res,rej){var r=new FileReader();r.onload=function(){res(String(r.result).split(',')[1]||'')};r.onerror=rej;r.readAsDataURL(b)})}
async function shrink(fl){
var im=await load(fl),w=im.naturalWidth,h=im.naturalHeight,s=Math.min(1,1280/Math.max(w,h));
for(var scale=s;scale>0.2;scale*=0.8){
var c=document.createElement('canvas');c.width=Math.max(1,Math.round(w*scale));c.height=Math.max(1,Math.round(h*scale));
var x=c.getContext('2d');x.fillStyle='#fff';x.fillRect(0,0,c.width,c.height);x.drawImage(im,0,0,c.width,c.height);
for(var q=0.8;q>=0.25;q-=0.1){var b=await toBlob(c,q);if(b&&b.size<=600000)return b}}
throw new Error('big')}
count();
file.addEventListener('change',async function(){
blob=null;prev.style.display='none';
var fl=file.files&&file.files[0];if(!fl){fname.textContent='no image chosen';return}
fname.textContent=fl.name;say('preparing...');
try{blob=await shrink(fl);prev.src=URL.createObjectURL(blob);prev.style.display='block';say(Math.round(blob.size/1024)+' kb, ready to send.')}
catch(e){file.value='';fname.textContent='no image chosen';say("couldn't read that picture. try another.",true)}});
f.addEventListener('submit',async function(ev){
ev.preventDefault();
var n=note.value.trim();if(!blob&&!n){say('add a picture or a note.',true);return}
btn.disabled=true;say('sending...');
try{var body={note:n};if(blob){body.image=await b64(blob);body.type='image/jpeg'}
var r=await fetch(IDEA.url,{method:'POST',headers:{'content-type':'application/json',accept:'application/json'},body:JSON.stringify(body)});
var j=await r.json().catch(function(){return{}});
if(r.ok&&j.ok){sent++;count();say(j.message||'sent. thank you.');f.reset();blob=null;prev.style.display='none';fname.textContent='no image chosen'}
else say(j.message||'that did not send. try again.',true)}
catch(e){say('that did not send. check your connection.',true)}
btn.disabled=false});
})();`;

export function ambassadorPage({ amb, stats, ideas = { total: 0, today: 0 }, designScans = {}, origin, flash }) {
  const school = SCHOOLS[amb.school];
  const schoolLower = school.name.toLowerCase();
  const links = ambassadorLinks(origin, amb);
  const base = `/a/${amb.token}`;
  const vars = { school: schoolLower, name: firstName(amb.name) };
  const designs = designsFor(amb.school);
  const recentByKey = Object.fromEntries(stats.byKeyRecent.map((r) => [`${r.kind}:${r.key}`, r.n]));
  const allByKey = Object.fromEntries(stats.byKeyAll.map((r) => [`${r.kind}:${r.key}`, r.n]));
  const dashboardHref = `/?school=${encodeURIComponent(amb.school)}`;

  const messagesHtml = messages.messages
    .map((m) => {
      const text = fillMsg(m.text, { ...vars, link: links.share(m.channel) });
      return `<div class="card">
        <div class="row" style="justify-content:space-between"><strong>${esc(m.label)}</strong>
          <button class="small" data-copy="${attr(text)}">copy message</button></div>
        <p class="msg">${esc(text)}</p>
        <p class="small muted mono">opens: ${allByKey[`link:${m.channel}`] ?? 0} total · ${recentByKey[`link:${m.channel}`] ?? 0} last ${stats.days}d</p>
      </div>`;
    })
    .join("");

  const postersHtml = designs
    .map((d) => {
      const img = posterImagePath(amb.school, d);
      const scans = designScans[scanKey(amb.school, d)] ?? 0;
      return `<div class="pcard">
        <img loading="lazy" src="${attr(img)}" alt="${attr(posterName(d))} poster">
        <div class="pb">
          <div class="pn">${esc(posterName(d).toLowerCase())}</div>
          <div class="ps">${scans} scan${scans === 1 ? "" : "s"} at ${esc(schoolLower)}</div>
          <a class="btn ghost small" href="${attr(img)}" target="_blank" rel="noopener">open full size</a>
          <button class="small" data-copy="${attr(links.poster(d))}">copy my link</button>
        </div>
      </div>`;
    })
    .join("");

  const dropChips = designs
    .map(
      (d) => `<label class="chip"><input type="radio" name="design" value="${attr(d)}" required>${esc(posterName(d).toLowerCase())}</label>`,
    )
    .join("");

  const channelChips = Object.entries(CHANNELS)
    .map(
      ([k, v]) => `<label class="chip"><input type="radio" name="channel" value="${attr(k)}" required>${esc(v)}</label>`,
    )
    .join("");

  const activityHtml = stats.activity.length
    ? `<table>${stats.activity
        .slice(0, 12)
        .map(
          (a) =>
            `<tr><td>${esc(a.kind === "drop" ? `${a.copies} × ${a.design}` : `posted in ${channelName(a.channel)}`)}${a.place ? ` <span class="muted">· ${esc(a.place)}</span>` : ""}</td><td class="num muted small">${esc(ago(a.ts))}</td></tr>`,
        )
        .join("")}</table>`
    : `<p class="muted">nothing logged yet. that's fine.</p>`;

  const paused = amb.paused_until && new Date(amb.paused_until) > new Date();

  const body = `
    <h1>hey ${esc(firstName(amb.name))}</h1>
    <p class="job"><b>the job: get smooth in front of as many eyes as you can.</b> spam the chats. put up posters. post every day.</p>
    <p class="muted">${esc(amb.title)}. nobody else sees this page.</p>
    <p class="noprint"><a class="btn small" href="smooth://ambassador?code=${attr(amb.token)}">open in the smooth app</a></p>
    ${flash ? `<p class="ok">${esc(flash)}</p>` : ""}

    <nav class="jumps noprint" aria-label="where things are">
      <a class="jump t-tomato" href="#posters"><span class="gl">${ICON_POSTERS}</span><b>all posters</b><span>every design, on this page</span></a>
      <a class="jump t-teal" href="${attr(dashboardHref)}" target="_blank" rel="noopener"><em>new tab</em><span class="gl">${ICON_DASH}</span><b>scan dashboard</b><span>live counts, every school</span></a>
      <a class="jump t-marigold" href="#idea"><span class="gl">${ICON_IDEA}</span><b>poster idea</b><span>send us a design</span></a>
    </nav>
    <nav class="tabs noprint">
      <a href="#numbers">numbers</a><a href="#posters">posters</a><a href="#idea">poster idea</a><a href="#messages">messages</a><a href="#drop">log a drop</a><a href="#feedback">feedback</a>
    </nav>

    <section class="sec t-teal"><h2 id="numbers">your numbers</h2>
      <div class="stats">
        <div class="stat t-tomato"><b>${stats.linkOpens + stats.posterOpens}</b><span>your link opens</span><small>${stats.linkOpensRecent + stats.posterOpensRecent} in ${stats.days}d</small></div>
        <div class="stat t-teal"><b>${stats.schoolScansTotal}</b><span>${esc(schoolLower)} poster scans</span><small>${stats.schoolScansRecent} in ${stats.days}d</small></div>
        <div class="stat t-marigold"><b>${stats.drops}</b><span>posters you've put up</span></div>
        <div class="stat t-grape"><b>${stats.posts}</b><span>posts you've logged</span></div>
      </div>
      <p class="small muted">opens are taps, repeats included, not people. <a href="${attr(dashboardHref)}" target="_blank" rel="noopener">${esc(schoolLower)} scan dashboard (new tab)</a></p>
    </section>

    <section class="sec t-tomato"><h2 id="posters">${esc(schoolLower)} posters</h2>
      <p class="small muted">open one full size to save or print it. my tracked link goes on your own posts: it counts for you.</p>
      <div class="pgrid">${postersHtml}</div>
      <p><a class="btn small ghost" href="${base}/stickers">your qr stickers (printable sheet)</a></p>
    </section>

    <section class="sec t-marigold"><h2 id="idea">send a poster idea</h2>
      <form id="ideaForm" method="post" action="${base}/idea">
        <div class="file"><label class="btn small ghost" style="margin:0;font:600 14px var(--body);color:var(--ink)"><input id="ideaFile" type="file" accept="image/*">choose image</label><span id="ideaFileName" class="small muted">no image chosen</span></div>
        <img id="ideaPreview" class="preview" alt="your chosen image">
        <label for="ideaNote">note (optional)</label>
        <textarea id="ideaNote" name="note" maxlength="500" placeholder="what's the idea, where would it go"></textarea>
        <p class="row"><button id="ideaSend" type="submit">send idea</button><span id="ideaCount" class="small muted mono">${ideas.total} of ${IDEA_TOTAL_LIMIT} sent</span></p>
        <p id="ideaMsg" class="small" role="status"></p>
      </form>
    </section>

    <section class="sec t-cobalt"><h2 id="messages">messages, ready to paste</h2>
      <p class="muted small">each carries your own link. change the words to sound like you.</p>
      ${messagesHtml}
      <details><summary>posting tips</summary><ul class="small">${messages.posting_tips.map((t) => `<li>${esc(t)}</li>`).join("")}</ul></details>
    </section>

    <section class="sec t-grape"><h2 id="drop">log a poster drop</h2>
      <form method="post" action="${base}/drop" class="card">
        <label>which design</label>
        <div class="chips">${dropChips}</div>
        <label>how many copies</label>
        <div class="row">${[1, 2, 3, 5, 10].map((n) => `<label class="chip"><input type="radio" name="copies" value="${n}" ${n === 1 ? "checked" : ""}>${n}</label>`).join("")}</div>
        <label>where (optional)</label>
        <input name="place" placeholder="e.g. library 1st floor, dorm lobby" maxlength="120" autocomplete="off">
        <p><button type="submit">log it</button></p>
      </form>
      <h2 style="margin-top:18px">log a post</h2>
      <form method="post" action="${base}/post" class="card">
        <label>where</label>
        <div class="chips">${channelChips}</div>
        <label>which chat / detail (optional)</label>
        <input name="place" placeholder="e.g. class of '28 gc" maxlength="120" autocomplete="off">
        <p><button type="submit">log it</button></p>
      </form>
    </section>

    <section class="sec t-lemon"><h2>recent</h2>${activityHtml}</section>

    <section class="sec t-cobalt"><h2 id="feedback">tell the founders something</h2>
      <form method="post" action="${base}/feedback">
        <textarea name="body" aria-label="feedback" placeholder="what's confusing, what's broken, what people said, what you'd change" maxlength="2000" required></textarea>
        <p><button type="submit">send</button></p>
        <p class="small muted">goes straight to olisa and marco. honest beats nice.</p>
      </form>
    </section>

    <section class="sec t-grape"><h2>reminders</h2>
      <p class="small">we text a short update about every two weeks, from a real phone. ${paused ? `<strong>paused until ${esc(String(amb.paused_until).slice(0, 10))}.</strong>` : ""}</p>
      <form method="post" action="${base}/pause" class="row">
        <button class="small ghost" name="weeks" value="4">pause 4 weeks</button>
        <button class="small ghost" name="weeks" value="12">pause the semester</button>
        ${paused ? `<button class="small" name="weeks" value="0">resume</button>` : ""}
      </form>
    </section>
    <p class="small muted">questions: text marco at +1 202 320 3802.</p>`;

  const script = `var IDEA=${scriptJSON({ url: `${base}/idea`, sent: ideas.total, limit: IDEA_TOTAL_LIMIT })};${IDEA_JS}`;
  return layout({ title: `smooth · ${firstName(amb.name)}`, body, script, who: `${amb.name} · ${schoolLower}` });
}

export function stickersPage({ amb, origin, qrSvg }) {
  const links = ambassadorLinks(origin, amb);
  const designs = designsFor(amb.school);
  const cards = designs
    .map(
      (d) => `<div class="card" style="text-align:center;padding:8px;margin:0">
        ${qrSvg(links.poster(d))}
        <div><strong>${esc(posterName(d).toLowerCase())}</strong></div>
        <div class="small muted">smooth for students</div>
      </div>`,
    )
    .join("");
  const body = `
    <p class="noprint"><a href=".">back to your page</a></p>
    <h1>your qr stickers</h1>
    <section class="sec t-tomato noprint"><h2>how it works</h2>
      <p class="small">print this page, cut them out, stick one over the code on a poster or next to it. scans count for ${esc(SCHOOLS[amb.school].name.toLowerCase())} and for you.</p>
      <p><button onclick="print()">print this sheet</button></p></section>
    <div class="grid" style="grid-template-columns:repeat(auto-fill,minmax(110px,1fr))">${cards}</div>`;
  return layout({ title: "smooth · stickers", body, who: `${amb.name} · ${SCHOOLS[amb.school].name.toLowerCase()}` });
}

// ------------------------------------------------------------------- founder

export function founderPage({ stats, origin, secret, flash, created }) {
  const base = `/f/${secret}`;
  const lb = stats.leaderboard;

  const createdHtml = created
    ? `<div class="card">
        <h3>added ${esc(created.name)} <span class="muted">(${esc(SCHOOLS[created.school].name)})</span></h3>
        <p class="small">their private page: <a href="${attr(ambassadorLinks(origin, created).page)}">${esc(ambassadorLinks(origin, created).page)}</a></p>
        <p class="msg">${esc(welcomeText({ amb: created, origin }))}</p>
        <p>${sendButton(created.contact, welcomeText({ amb: created, origin }), "text the welcome")}
        <form method="post" action="${base}/reminder" style="display:inline"><input type="hidden" name="id" value="${created.id}"><input type="hidden" name="kind" value="welcome"><button class="small ghost">mark sent</button></form></p>
      </div>`
    : "";

  const rosterRows = stats.ambassadors
    .map(
      (a) => `<details class="card">
        <summary>${esc(a.name)} <span class="muted">· ${esc(SCHOOLS[a.school]?.name ?? a.school)} · ${esc(a.status)}${a.paused ? " · paused" : ""}${a.skipDigest && !a.paused ? " · quiet (2 unanswered)" : ""}</span>
          <span class="small muted" style="float:right">${a.linkOpensRecent + a.posterOpensRecent} opens/${stats.days}d</span></summary>
        <table class="small">
          <tr><td>contact</td><td>${esc(a.contact || "—")}</td></tr>
          <tr><td>page</td><td><a href="${attr(ambassadorLinks(origin, a).page)}">open</a> · <button class="small ghost" data-copy="${attr(ambassadorLinks(origin, a).page)}">copy link</button></td></tr>
          <tr><td>opens</td><td>${a.linkOpens} links · ${a.posterOpens} stickers (${a.linkOpensRecent + a.posterOpensRecent} in ${stats.days}d)</td></tr>
          <tr><td>did</td><td>${a.drops} posters · ${a.posts} posts · last ${esc(ago(a.lastActivity))}</td></tr>
          <tr><td>last reminder</td><td>${a.lastReminder ? `${esc(a.lastReminder.kind)} ${esc(ago(a.lastReminder.ts))}${a.lastReminder.replied ? " · replied" : ""}` : "none"}</td></tr>
        </table>
        <form method="post" action="${base}/update" class="row small">
          <input type="hidden" name="id" value="${a.id}">
          <select name="status" aria-label="status">${["invited", "active", "paused", "left"].map((s) => `<option ${s === a.status ? "selected" : ""}>${s}</option>`).join("")}</select>
          <input name="title" value="${attr(a.title)}" aria-label="title" placeholder="title">
          <input name="contact" value="${attr(a.contact)}" aria-label="contact" placeholder="contact">
          <input name="notes" value="${attr(a.notes)}" aria-label="notes" placeholder="notes">
          <button class="small ghost">save</button>
        </form>
        <form method="post" action="${base}/replied" class="row small"><input type="hidden" name="id" value="${a.id}"><button class="small ghost">they replied</button></form>
      </details>`,
    )
    .join("");

  const digestRows = stats.ambassadors
    .filter((a) => a.status !== "left")
    .map((a, i) => {
      const text = digestText({ amb: a, origin, leaderboard: lb, week: Math.floor(Date.now() / (14 * 86400000)) + i });
      return `<div class="card ${a.skipDigest ? "muted" : ""}">
        <div class="row" style="justify-content:space-between"><strong>${esc(a.name)}</strong><span class="small">${a.skipDigest ? (a.paused ? "paused, skip" : "quiet after 2 unanswered, skip until a campus moment") : ""}</span></div>
        <p class="msg small">${esc(text)}</p>
        <p>${sendButton(a.contact, text)}
          <form method="post" action="${base}/reminder" style="display:inline"><input type="hidden" name="id" value="${a.id}"><input type="hidden" name="kind" value="digest"><button class="small ghost">mark sent</button></form></p>
      </div>`;
    })
    .join("");

  const momentOptions = moments.moments.map((m) => `<option value="${attr(m.key)}">${esc(m.label)} · ${esc(m.when)}</option>`).join("");
  const momentRows = stats.ambassadors
    .filter((a) => !a.paused && a.status !== "left")
    .map((a) => {
      const id = `m-${a.id}`;
      return `<div class="card" data-moment-card data-id="${a.id}" data-name="${attr(a.name)}">
        <strong>${esc(a.name)}</strong> <span class="muted small">${esc(SCHOOLS[a.school]?.name ?? "")}</span>
        <p class="msg small" id="${id}"></p>
        <p><span data-send></span>
        <form method="post" action="${base}/reminder" style="display:inline"><input type="hidden" name="id" value="${a.id}"><input type="hidden" name="kind" value="" data-kind><button class="small ghost">mark sent</button></form></p>
      </div>`;
    })
    .join("");
  const momentData = {};
  for (const a of stats.ambassadors)
    momentData[a.id] = Object.fromEntries(
      moments.moments.map((m) => {
        const t = momentTexts({ amb: a, origin, key: m.key });
        return [m.key, { text: t.combined, sms: smsLink(a.contact, t.combined) }];
      }),
    );

  const feedbackHtml = stats.feedback.length
    ? stats.feedback
        .map(
          (f) => `<div class="card ${f.seen ? "muted" : ""}"><p class="small muted">${esc(f.name)} · ${esc(SCHOOLS[f.school]?.name ?? "")} · ${esc(ago(f.ts))}</p><p>${esc(f.body)}</p>
          ${f.seen ? "" : `<form method="post" action="${base}/feedback-seen"><input type="hidden" name="id" value="${f.id}"><button class="small ghost">seen</button></form>`}</div>`,
        )
        .join("")
    : `<p class="muted">no feedback yet.</p>`;

  const activityHtml = stats.activity.length
    ? `<table class="small">${stats.activity
        .slice(0, 40)
        .map(
          (a) =>
            `<tr><td>${esc(a.name)} <span class="muted">${esc(SCHOOLS[a.school]?.name ?? "")}</span></td><td>${esc(a.kind === "drop" ? `${a.copies} × ${a.design}` : `post · ${channelName(a.channel)}`)}${a.place ? ` <span class="muted">· ${esc(a.place)}</span>` : ""}</td><td class="num muted">${esc(ago(a.ts))}</td></tr>`,
        )
        .join("")}</table>`
    : `<p class="muted">nothing logged yet.</p>`;

  const newIdeas = stats.ideas.filter((i) => !i.seenAt).length;
  const ideasHtml = stats.ideas.length
    ? stats.ideas
        .map(
          (i) => `<div class="card ${i.seenAt ? "muted" : ""}">
          <p class="small muted mono">${esc(i.ambassador)} · ${esc(SCHOOLS[i.school]?.name ?? i.school)} · ${esc(ago(i.ts))}${i.seenAt ? " · seen" : ""}</p>
          ${i.note ? `<p class="msg">${esc(i.note)}</p>` : ""}
          ${i.hasImage ? `<a href="${base}/idea/${i.id}" target="_blank" rel="noopener"><img class="thumb" loading="lazy" src="${base}/idea/${i.id}" alt="poster idea from ${attr(i.ambassador)}"></a>` : ""}
          <div class="row">
            ${i.seenAt ? "" : `<form method="post" action="${base}/idea-seen"><input type="hidden" name="id" value="${i.id}"><button class="small">seen</button></form>`}
            <form method="post" action="${base}/idea-delete" onsubmit="return confirm('delete this idea?')"><input type="hidden" name="id" value="${i.id}"><button class="small ghost">delete</button></form>
          </div></div>`,
        )
        .join("")
    : `<p class="muted">no ideas yet.</p>`;

  const body = `
    <h1>ambassadors</h1>
    <p class="muted small">private. this url is the key, don't share it.</p>
    <p class="row noprint"><a class="btn small ghost" href="${base}/export.json">export json</a><a class="btn small ghost" href="/" target="_blank" rel="noopener">public dashboard (new tab)</a></p>
    ${flash ? `<p class="ok">${esc(flash)}</p>` : ""}
    <nav class="tabs">
      <a href="#ideas">poster ideas${newIdeas ? ` · ${newIdeas}` : ""}</a><a href="#perf">performance</a><a href="#roster">roster</a><a href="#add">add</a><a href="#digest">digest</a><a href="#moments">campus moments</a><a href="#feedback">feedback</a>
    </nav>
    ${createdHtml}

    <section class="sec t-marigold"><h2 id="ideas">poster ideas <span class="muted">${newIdeas} new · ${stats.ideas.length} total</span></h2>
      ${ideasHtml}
    </section>

    <section class="sec t-teal"><h2 id="perf">by school <span class="muted">last ${stats.days} days</span></h2>
    <table>
      <tr><th>#</th><th>school</th><th class="num">poster scans</th><th class="num">link opens</th><th class="num">all-time</th><th class="num">ambs</th></tr>
      ${lb.schools.map((s) => `<tr><td>${s.rank}</td><td>${esc(s.name)}</td><td class="num">${s.recent}</td><td class="num">${s.linkOpensRecent}</td><td class="num">${s.total}</td><td class="num">${s.ambassadors}</td></tr>`).join("")}
    </table>
    <details><summary>by design</summary>
      <table class="small"><tr><th>school</th><th>design</th><th class="num">${stats.days}d</th><th class="num">total</th></tr>
      ${stats.designs.filter((d) => d.total || d.recent).map((d) => `<tr><td>${esc(SCHOOLS[d.school].name)}</td><td>${esc(d.design)}</td><td class="num">${d.recent}</td><td class="num">${d.total}</td></tr>`).join("")}
      </table></details>
    <details><summary>by ambassador</summary>
      <table class="small"><tr><th>name</th><th>school</th><th class="num">opens ${stats.days}d</th><th class="num">all</th><th class="num">posters</th><th class="num">posts</th></tr>
      ${[...stats.ambassadors].sort((a, b) => b.linkOpensRecent + b.posterOpensRecent - (a.linkOpensRecent + a.posterOpensRecent)).map((a) => `<tr><td>${esc(a.name)}</td><td>${esc(SCHOOLS[a.school]?.name ?? "")}</td><td class="num">${a.linkOpensRecent + a.posterOpensRecent}</td><td class="num">${a.linkOpens + a.posterOpens}</td><td class="num">${a.drops}</td><td class="num">${a.posts}</td></tr>`).join("")}
      </table></details>
    </section>

    <section class="sec t-tomato"><h2 id="roster">roster <span class="muted">${stats.ambassadors.length}</span></h2>
    ${rosterRows || `<p class="muted">nobody yet. add your first friend below.</p>`}
    </section>

    <section class="sec t-cobalt"><h2 id="add">add an ambassador</h2>
    <form method="post" action="${base}/add" class="card">
      <label>name</label><input name="name" required maxlength="80" autocomplete="off">
      <label>school</label><select name="school">${Object.entries(SCHOOLS).map(([k, s]) => `<option value="${attr(k)}">${esc(s.name)}</option>`).join("")}</select>
      <label>contact (phone is best, enables one-tap texts)</label><input name="contact" maxlength="120" autocomplete="off" inputmode="tel">
      <label>notes (optional)</label><input name="notes" maxlength="500" autocomplete="off">
      <p><button>add and get their link</button></p>
    </form>
    </section>

    <section class="sec t-grape"><h2 id="digest">two-week digest</h2>
    <p class="muted small">built from real numbers right now. tap "text it", send from your phone, then "mark sent". anyone paused or silent after two digests is skipped automatically.</p>
    ${digestRows || `<p class="muted">add ambassadors first.</p>`}
    </section>

    <section class="sec t-lemon"><h2 id="moments">campus moments</h2>
    <p class="muted small">pick the moment, the texts fill in per person. these go out even to the quiet ones (never to paused).</p>
    <select id="moment" aria-label="campus moment" onchange="applyMoment()" style="margin-bottom:8px">${momentOptions}</select>
    ${momentRows || `<p class="muted">add ambassadors first.</p>`}
    </section>

    <section class="sec t-cobalt"><h2 id="feedback">feedback <span class="muted">${stats.feedback.filter((f) => !f.seen).length} new</span></h2>
    ${feedbackHtml}
    </section>

    <section class="sec t-teal"><h2>activity</h2>
    ${activityHtml}
    </section>`;

  const script = `
    var MOMENTS=${scriptJSON(momentData)};
    function applyMoment(){var k=document.getElementById('moment').value;document.querySelectorAll('[data-moment-card]').forEach(function(c){var id=c.getAttribute('data-id');var m=MOMENTS[id]&&MOMENTS[id][k];if(!m)return;c.querySelector('.msg').textContent=m.text;var s=c.querySelector('[data-send]');s.innerHTML='';if(m.sms){var a=document.createElement('a');a.className='btn small';a.href=m.sms;a.textContent='text it';s.appendChild(a);s.appendChild(document.createTextNode(' '))}var b=document.createElement('button');b.className='small ghost';b.setAttribute('data-copy',m.text);b.textContent='copy';s.appendChild(b);c.querySelector('[data-kind]').value='moment:'+k})}
    applyMoment();`;

  return layout({ title: "smooth · founders", body, script, wide: true, who: "founders" });
}
