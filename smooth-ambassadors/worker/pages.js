// Page rendering for ambassadors (/a/{token}) and founders (/f/{secret}).
import { SCHOOLS, CHANNELS, offeredDesignsFor, posterImagePath, posterName, scanKey } from "./catalog.js";
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

// The client half of "show us your feed" and "how did a post do". Each picture
// is shrunk on a canvas (longest side 1200px, JPEG, quality lowered until it is
// under the size the server allows) and posted as JSON, one request per
// picture. The server checks everything again, so none of this is trusted.
const CAPTURE_JS = String.raw`
(function(){
if(typeof CAPTURE==='undefined')return;
function load(fl){return new Promise(function(res,rej){var u=URL.createObjectURL(fl),im=new Image();im.onload=function(){URL.revokeObjectURL(u);res(im)};im.onerror=function(){URL.revokeObjectURL(u);rej(new Error('bad'))};im.src=u})}
function toBlob(c,q){return new Promise(function(r){c.toBlob(r,'image/jpeg',q)})}
function b64(b){return new Promise(function(res,rej){var r=new FileReader();r.onload=function(){res(String(r.result).split(',')[1]||'')};r.onerror=rej;r.readAsDataURL(b)})}
async function shrink(fl,max){
var im=await load(fl),w=im.naturalWidth,h=im.naturalHeight,s=Math.min(1,1200/Math.max(w,h));
for(var scale=s;scale>0.15;scale*=0.8){
var c=document.createElement('canvas');c.width=Math.max(1,Math.round(w*scale));c.height=Math.max(1,Math.round(h*scale));
var x=c.getContext('2d');x.fillStyle='#fff';x.fillRect(0,0,c.width,c.height);x.drawImage(im,0,0,c.width,c.height);
for(var q=0.8;q>=0.25;q-=0.1){var b=await toBlob(c,q);if(b&&b.size<=max)return b}}
throw new Error('big')}
function num(v){return String(v).replace(/[,\s]/g,'')}
function say(el,t,bad){el.textContent=t;el.className='small'+(bad?' err':'')}
async function send(body){
var r=await fetch(CAPTURE.url,{method:'POST',headers:{'content-type':'application/json',accept:'application/json'},body:JSON.stringify(body)});
var j=await r.json().catch(function(){return{}});
return{ok:r.ok&&j.ok,message:j.message,status:r.status}}
function batchId(){var a='abcdefghijklmnopqrstuvwxyz0123456789',o='',v=new Uint8Array(12);
if(window.crypto&&crypto.getRandomValues)crypto.getRandomValues(v);else for(var i=0;i<12;i++)v[i]=Math.floor(Math.random()*256);
for(var k=0;k<12;k++)o+=a[v[k]%a.length];return o}

var ff=document.getElementById('feedForm');
if(ff){
var fin=document.getElementById('feedFiles'),fmsg=document.getElementById('feedMsg'),fbtn=document.getElementById('feedSend'),fcnt=document.getElementById('feedCount'),fname=document.getElementById('feedFileName');
var fs=CAPTURE.feed;
function fcount(){fcnt.textContent=fs.sentToday+' of '+fs.dailyLimit+' today'}
fcount();
// batch and sent belong to the current file selection: a failed press resumes
// at the first unsent frame under the same batch id (the server answers 200 for a
// batch+seq it already holds, so re-sending the failed one is safe), and choosing
// new files starts a new batch.
var batch=null,sent=0,busy=false;
function reset(){batch=null;sent=0}
fin.addEventListener('change',function(){reset();var n=fin.files?fin.files.length:0;fname.textContent=n?(n>fs.framesPerRecording?fs.framesPerRecording+' of '+n+' pictures will be sent':n+(n===1?' picture':' pictures')):'no pictures chosen'});
ff.addEventListener('submit',async function(ev){
ev.preventDefault();
if(busy)return;
var files=Array.prototype.slice.call(fin.files||[],0,fs.framesPerRecording);
if(!files.length){say(fmsg,'choose a few screenshots first.',true);return}
if(sent>=files.length)reset();
if(!batch)batch=batchId();
busy=true;fbtn.disabled=true;
try{
while(sent<files.length){
say(fmsg,'sent '+sent+' of '+files.length+'...');
var blob=await shrink(files[sent],fs.frameBytes);
var res=await send({kind:'feed',batch:batch,seq:sent,image:await b64(blob)});
if(!res.ok){say(fmsg,(res.message||'that did not send. try again.')+' ('+sent+' of '+files.length+' sent)',true);return}
sent++;fs.sentToday++;fs.stored++;fcount()}
say(fmsg,'sent '+sent+' of '+files.length+'. thank you.');ff.reset();fname.textContent='no pictures chosen';reset()}
catch(e){say(fmsg,'that did not send. press send to try again. ('+sent+' of '+files.length+' sent)',true)}
finally{busy=false;fbtn.disabled=false}})}

var rf=document.getElementById('resultForm');
if(rf){
var rin=document.getElementById('resultFile'),rmsg=document.getElementById('resultMsg'),rbtn=document.getElementById('resultSend'),rcnt=document.getElementById('resultCount'),rname=document.getElementById('resultFileName'),rs=CAPTURE.results;
function rcount(){rcnt.textContent=rs.sentToday+' of '+rs.dailyLimit+' today'}
rcount();
rin.addEventListener('change',function(){var fl=rin.files&&rin.files[0];rname.textContent=fl?fl.name:'no image chosen'});
function checked(name){var e=rf.querySelector('input[name='+name+']:checked');return e?e.value:''}
rf.addEventListener('submit',async function(ev){
ev.preventDefault();
var fl=rin.files&&rin.files[0];if(!fl){say(rmsg,'choose the screenshot first.',true);return}
rbtn.disabled=true;say(rmsg,'sending...');
try{var blob=await shrink(fl,rs.imageBytes);
var res=await send({kind:'result',image:await b64(blob),platform:checked('platform'),style:checked('style'),upvotes:num(rf.elements.upvotes.value),views:num(rf.elements.views.value),note:rf.elements.note.value});
if(res.ok){rs.sentToday++;rs.stored++;rcount();say(rmsg,res.message||'sent.');rf.reset();rname.textContent='no image chosen'}
else say(rmsg,res.message||'that did not send. try again.',true)}
catch(e){say(rmsg,"couldn't read that picture. try another.",true)}
rbtn.disabled=false})}
})();`;

export function ambassadorPage({
  amb,
  stats,
  ideas = { total: 0, today: 0 },
  designScans = {},
  playbook = null,
  suggested = [],
  captures = null,
  origin,
  flash,
}) {
  const school = SCHOOLS[amb.school];
  const schoolLower = school.name.toLowerCase();
  const links = ambassadorLinks(origin, amb);
  const base = `/a/${amb.token}`;
  const vars = { school: schoolLower, name: firstName(amb.name) };
  const designs = offeredDesignsFor(amb.school);
  const recentByKey = Object.fromEntries(stats.byKeyRecent.map((r) => [`${r.kind}:${r.key}`, r.n]));
  const allByKey = Object.fromEntries(stats.byKeyAll.map((r) => [`${r.kind}:${r.key}`, r.n]));
  const dashboardHref = `/?school=${encodeURIComponent(amb.school)}`;

  const messagesHtml = messages.messages
    .map((m) => {
      const text = fillMsg(m.text, { ...vars, link: links.share(m.channel) });
      // Since 2026-11-19 the bank is two posts with no link in them (the pitch
      // is the reply), so an "opens" count under one would always describe a
      // link the card does not show. It stays for any post that carries one.
      const hasLink = m.text.includes("{link}");
      return `<div class="card">
        <div class="row" style="justify-content:space-between"><strong>${esc(m.label)}</strong>
          <button class="small" data-copy="${attr(text)}">copy message</button></div>
        <p class="msg" style="white-space:pre-line">${esc(text)}</p>
        ${m.reply ? `<div class="row" style="justify-content:space-between"><p class="small"><b>then reply:</b> ${esc(m.reply)}</p><button class="small ghost" data-copy="${attr(m.reply)}">copy reply</button></div>` : ""}
        ${hasLink ? `<p class="small muted mono">opens: ${allByKey[`link:${m.channel}`] ?? 0} total · ${recentByKey[`link:${m.channel}`] ?? 0} last ${stats.days}d</p>` : ""}
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

  // "what works": static, from templates/playbook.json. Every string is escaped
  // even though it is ours, so a future edit cannot put markup on the page.
  const exampleHtml = (playbook?.examples ?? [])
    .map(
      (e) => `<div class="card">
        <p class="sh">${esc(e.title)}</p>
        <p class="msg" style="white-space:pre-line">${esc(e.post)}</p>
        <p class="small"><b>reply:</b> ${esc(e.reply)}</p>
        <p class="small mono">${esc(e.score)}</p>
        <p class="small muted">${esc(e.why)}</p>
      </div>`,
    )
    .join("");
  const playbookHtml = playbook
    ? `<section class="sec t-lemon"><h2 id="works">what works</h2>
      <p><b>${esc(playbook.lead)}</b></p>
      <ul>${playbook.steps.map((t) => `<li>${esc(t)}</li>`).join("")}</ul>
      ${exampleHtml}
    </section>`
    : "";
  const suggestedHtml = suggested.length
    ? `<section class="sec t-grape"><h2 id="try">posts to try, from olisa and marco</h2>
      ${suggested
        .map(
          (x) => `<div class="card">
        <p class="msg" style="white-space:pre-line">${esc(x.text)}</p>
        ${x.reply ? `<p class="small"><b>reply:</b> ${esc(x.reply)}</p>` : ""}
        <p><button class="small" data-copy="${attr(x.text)}">copy post</button>${x.reply ? ` <button class="small ghost" data-copy="${attr(x.reply)}">copy reply</button>` : ""}</p>
      </div>`,
        )
        .join("")}
    </section>`
    : "";
  const cap = captures ?? {
    feed: { framesPerRecording: 16, frameBytes: 200000, sentToday: 0, dailyLimit: 32, stored: 0, limit: 96 },
    results: { imageBytes: 300000, sentToday: 0, dailyLimit: 8, stored: 0, limit: 60 },
    styles: [],
  };
  const platformChips = [["fizz", "fizz"], ["sidechat", "sidechat"], ["yikyak", "yik yak"], ["other", "other"]]
    .map(([k, v]) => `<label class="chip"><input type="radio" name="platform" value="${attr(k)}"${k === "fizz" ? " checked" : ""}>${esc(v)}</label>`)
    .join("");
  const styleChips = cap.styles
    .map((st, i) => `<label class="chip"><input type="radio" name="style" value="${attr(st.key)}"${i === 0 ? " checked" : ""}>${esc(st.label)}</label>`)
    .join("");

  const body = `
    <h1>hey ${esc(firstName(amb.name))}</h1>
    <p class="job"><b>the job: get smooth in front of as many eyes as you can.</b> spam the chats. put up posters. post every day. bring back what people say and ideas for smooth.</p>
    <p class="muted">${esc(amb.title)}. nobody else sees this page.</p>
    <p class="noprint"><a class="btn small" href="smooth://ambassador?code=${attr(amb.token)}">open in the smooth app</a></p>
    ${flash ? `<p class="ok">${esc(flash)}</p>` : ""}

    <nav class="jumps noprint" aria-label="where things are">
      <a class="jump t-tomato" href="#posters"><span class="gl">${ICON_POSTERS}</span><b>all posters</b><span>every design, on this page</span></a>
      <a class="jump t-teal" href="${attr(dashboardHref)}" target="_blank" rel="noopener"><em>new tab</em><span class="gl">${ICON_DASH}</span><b>scan dashboard</b><span>live counts, every school</span></a>
      <a class="jump t-marigold" href="#idea"><span class="gl">${ICON_IDEA}</span><b>poster idea</b><span>send us a design</span></a>
    </nav>
    <nav class="tabs noprint">
      <a href="#works">what works</a>${suggested.length ? `<a href="#try">posts to try</a>` : ""}<a href="#numbers">numbers</a><a href="#posters">posters</a><a href="#idea">poster idea</a><a href="#feed">your feed</a><a href="#result">post result</a><a href="#messages">messages</a><a href="#drop">log a drop</a><a href="#feedback">feedback</a>
    </nav>

    ${playbookHtml}
    ${suggestedHtml}
    <section class="sec t-teal"><h2 id="numbers">your numbers</h2>
      <div class="stats">
        <div class="stat t-tomato"><b>${stats.linkOpens + stats.posterOpens}</b><span>your link opens</span><small>${stats.linkOpensRecent + stats.posterOpensRecent} in ${stats.days}d</small></div>
        <div class="stat t-teal"><b>${stats.schoolScansTotal}</b><span>${esc(schoolLower)} poster scans</span><small>${stats.schoolScansRecent} in ${stats.days}d</small></div>
        <div class="stat t-marigold"><b>${stats.drops}</b><span>posters you've put up</span></div>
        <div class="stat t-grape"><b>${stats.posts}</b><span>posts you've logged</span></div>
      </div>
      <p class="small muted">opens are taps, repeats included, not people. <a href="${attr(dashboardHref)}" target="_blank" rel="noopener">${esc(schoolLower)} scan dashboard (new tab)</a></p>
      <p class="small muted">for dms and group chats: <button class="small" data-copy="${attr(links.share("dm"))}">copy my link</button></p>
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

    <section class="sec t-teal"><h2 id="feed">show us your feed</h2>
      <p class="small">scroll your school's anonymous feed and screenshot what's getting upvotes.</p>
      <p class="small">we'll write posts for you from it.</p>
      <form id="feedForm" method="post" action="${base}/capture">
        <div class="file"><label class="btn small ghost" style="margin:0;font:600 14px var(--body);color:var(--ink)"><input id="feedFiles" type="file" accept="image/*" multiple>choose screenshots</label><span id="feedFileName" class="small muted">no pictures chosen</span></div>
        <p class="row"><button id="feedSend" type="submit">send</button><span id="feedCount" class="small muted mono"></span></p>
        <p id="feedMsg" class="small" role="status"></p>
        <p class="small muted">check nothing private is in the pictures.</p>
      </form>
    </section>

    <section class="sec t-tomato"><h2 id="result">how did a post do</h2>
      <form id="resultForm" method="post" action="${base}/capture">
        <div class="file"><label class="btn small ghost" style="margin:0;font:600 14px var(--body);color:var(--ink)"><input id="resultFile" type="file" accept="image/*">choose screenshot</label><span id="resultFileName" class="small muted">no image chosen</span></div>
        <label>where</label>
        <div class="chips">${platformChips}</div>
        <label>what kind of post</label>
        <div class="chips">${styleChips}</div>
        <label for="resultUp">upvotes (optional)</label>
        <input id="resultUp" name="upvotes" inputmode="numeric" maxlength="8" autocomplete="off">
        <label for="resultViews">views (optional)</label>
        <input id="resultViews" name="views" inputmode="numeric" maxlength="8" autocomplete="off">
        <label for="resultNote">note (optional)</label>
        <textarea id="resultNote" name="note" maxlength="300" placeholder="anything we should know"></textarea>
        <p class="row"><button id="resultSend" type="submit">send</button><span id="resultCount" class="small muted mono"></span></p>
        <p id="resultMsg" class="small" role="status"></p>
      </form>
    </section>

    <section class="sec t-cobalt"><h2 id="messages">messages, ready to paste</h2>
      <p class="muted small">no link in the post. swap in your own school's names.</p>
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

    <section class="sec t-cobalt"><h2 id="feedback">feedback and ideas for smooth</h2>
      <form method="post" action="${base}/feedback">
        <textarea name="body" aria-label="feedback" placeholder="what people said, what's broken, what's confusing, ideas for smooth" maxlength="2000" required></textarea>
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

  const script = `var IDEA=${scriptJSON({ url: `${base}/idea`, sent: ideas.total, limit: IDEA_TOTAL_LIMIT })};${IDEA_JS}var CAPTURE=${scriptJSON({ url: `${base}/capture`, feed: cap.feed, results: cap.results })};${CAPTURE_JS}`;
  return layout({ title: `smooth · ${firstName(amb.name)}`, body, script, who: `${amb.name} · ${schoolLower}` });
}

export function stickersPage({ amb, origin, qrSvg }) {
  const links = ambassadorLinks(origin, amb);
  const designs = offeredDesignsFor(amb.school);
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
  const suggestions = stats.suggestions ?? [];
  const suggestionsOf = (id) => {
    const mine = suggestions.filter((x) => x.ambassadorId === id);
    return mine.length
      ? `<div class="small"><strong>posts to try</strong>${mine
          .map(
            (x) => `<div class="row"><span class="msg">${esc(x.text)}${x.reply ? ` <span class="muted">· reply: ${esc(x.reply)}</span>` : ""}</span>
          <form method="post" action="${base}/suggest-delete"><input type="hidden" name="id" value="${x.id}"><button class="small ghost">delete</button></form></div>`,
          )
          .join("")}</div>`
      : "";
  };


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
        ${suggestionsOf(a.id)}
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

  const captures = stats.captures ?? [];
  const stamp = (ts) => esc(ago(ts));
  const thumb = (c) =>
    `<a href="${base}/capture/${c.id}" target="_blank" rel="noopener"><img class="thumb" style="display:inline-block;max-width:90px;max-height:90px;margin:2px" loading="lazy" src="${base}/capture/${c.id}" alt="capture from ${attr(c.ambassador)}"></a>`;

  // One card per recording: the stills share an ambassador and a batch id.
  const feedRows = captures.filter((c) => c.kind === "feed");
  const batches = new Map();
  for (const c of feedRows) {
    const key = `${c.ambassadorId}/${c.batch}`;
    if (!batches.has(key)) batches.set(key, { first: c, frames: [] });
    batches.get(key).frames.push(c);
  }
  const newFeeds = [...batches.values()].filter((b) => b.frames.some((c) => !c.seenAt)).length;
  const feedsHtml = batches.size
    ? [...batches.values()]
        .sort((a, b) => (a.first.ts < b.first.ts ? 1 : -1))
        .map((b) => {
          const c = b.first;
          const hidden = `<input type="hidden" name="amb" value="${c.ambassadorId}"><input type="hidden" name="batch" value="${attr(c.batch)}">`;
          const unseen = b.frames.some((x) => !x.seenAt);
          return `<div class="card ${unseen ? "" : "muted"}">
          <p class="small muted mono">${esc(c.ambassador)} · ${esc(SCHOOLS[c.school]?.name ?? c.school)} · ${stamp(c.ts)} · ${b.frames.length} frame${b.frames.length === 1 ? "" : "s"}${unseen ? "" : " · seen"}</p>
          <div>${[...b.frames].sort((x, y) => x.seq - y.seq).map(thumb).join("")}</div>
          <form method="post" action="${base}/suggest" class="small">
            <input type="hidden" name="id" value="${c.ambassadorId}">
            <label>send a post to try</label>
            <textarea name="text" maxlength="600" required aria-label="post to try"></textarea>
            <input name="reply" maxlength="300" placeholder="reply to leave under it (optional)" aria-label="reply">
            <button class="small">send a post to try</button>
          </form>
          <div class="row">
            ${unseen ? `<form method="post" action="${base}/capture-seen">${hidden}<button class="small">seen</button></form>` : ""}
            <form method="post" action="${base}/capture-delete" onsubmit="return confirm('delete this recording?')">${hidden}<button class="small ghost">delete</button></form>
          </div></div>`;
        })
        .join("")
    : `<p class="muted">no recordings yet.</p>`;

  const resultRows = captures.filter((c) => c.kind === "result");
  const avg = (xs) => {
    const v = xs.filter((n) => n !== null && n !== undefined);
    return v.length ? Math.round(v.reduce((a, n) => a + n, 0) / v.length) : "—";
  };
  const byStyle = {};
  for (const r of resultRows) (byStyle[r.style || "other"] ??= []).push(r);
  const styleTable = resultRows.length
    ? `<table class="small"><tr><th>style</th><th class="num">posts</th><th class="num">avg upvotes</th><th class="num">avg views</th></tr>
      ${Object.entries(byStyle).map(([k, rs]) => `<tr><td>${esc(k)}</td><td class="num">${rs.length}</td><td class="num">${avg(rs.map((r) => r.upvotes))}</td><td class="num">${avg(rs.map((r) => r.views))}</td></tr>`).join("")}</table>`
    : "";
  const resultsHtml = resultRows.length
    ? `${styleTable}${resultRows
        .map(
          (r) => `<div class="card">
        <p class="small mono">${esc(r.ambassador)} · ${esc(SCHOOLS[r.school]?.name ?? r.school)} · ${stamp(r.ts)}</p>
        <p class="small">${esc(r.platform)} · ${esc(r.style)} · <b>${r.upvotes ?? "—"}</b> upvotes · <b>${r.views ?? "—"}</b> views</p>
        ${r.note ? `<p class="msg">${esc(r.note)}</p>` : ""}
        <div>${thumb(r)}</div>
        <form method="post" action="${base}/capture-delete" onsubmit="return confirm('delete this result?')"><input type="hidden" name="id" value="${r.id}"><button class="small ghost">delete</button></form>
      </div>`,
        )
        .join("")}`
    : `<p class="muted">no results yet.</p>`;

  const body = `
    <h1>ambassadors</h1>
    <p class="muted small">private. this url is the key, don't share it.</p>
    <p class="row noprint"><a class="btn small ghost" href="${base}/export.json">export json</a><a class="btn small ghost" href="/" target="_blank" rel="noopener">public dashboard (new tab)</a></p>
    ${flash ? `<p class="ok">${esc(flash)}</p>` : ""}
    <nav class="tabs">
      <a href="#ideas">poster ideas${newIdeas ? ` · ${newIdeas}` : ""}</a><a href="#feeds">feed recordings${newFeeds ? ` · ${newFeeds}` : ""}</a><a href="#results">post results</a><a href="#perf">performance</a><a href="#roster">roster</a><a href="#add">add</a><a href="#digest">digest</a><a href="#moments">campus moments</a><a href="#feedback">feedback</a>
    </nav>
    ${createdHtml}

    <section class="sec t-marigold"><h2 id="ideas">poster ideas <span class="muted">${newIdeas} new · ${stats.ideas.length} total</span></h2>
      ${ideasHtml}
    </section>

    <section class="sec t-teal"><h2 id="feeds">feed recordings <span class="muted">${newFeeds} new · ${batches.size} total</span></h2>
      ${feedsHtml}
    </section>

    <section class="sec t-tomato"><h2 id="results">post results <span class="muted">${resultRows.length} total</span></h2>
      ${resultsHtml}
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
