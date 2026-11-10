// Page rendering for ambassadors (/a/{token}) and founders (/f/{secret}).
import { SCHOOLS, CHANNELS, designsFor, posterImagePath, posterName } from "./catalog.js";
import { layout, esc, attr } from "./html.js";
import { isPhone, phoneForSms } from "./data.js";
import { ambassadorLinks, digestText, welcomeText, momentTexts, moments, firstName } from "./digest.js";
import messages from "./templates/messages.json";
import checklist from "./templates/checklist.json";

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

export function ambassadorPage({ amb, stats, origin, flash }) {
  const school = SCHOOLS[amb.school];
  const links = ambassadorLinks(origin, amb);
  const base = `/a/${amb.token}`;
  const vars = { school: school.name.toLowerCase(), name: firstName(amb.name) };
  const designs = designsFor(amb.school);
  const recentByKey = Object.fromEntries(stats.byKeyRecent.map((r) => [`${r.kind}:${r.key}`, r.n]));
  const allByKey = Object.fromEntries(stats.byKeyAll.map((r) => [`${r.kind}:${r.key}`, r.n]));

  const checklistHtml = checklist.steps
    .map((s) => {
      const done = stats.checked.has(s.key);
      return `<form method="post" action="${base}/check" class="check">
        <input type="hidden" name="step" value="${attr(s.key)}">
        <input type="hidden" name="done" value="${done ? 0 : 1}">
        <input type="checkbox" ${done ? "checked" : ""} onchange="this.form.submit()" aria-label="${attr(s.label)}">
        <div><div class="${done ? "done" : ""}">${esc(s.label)}</div><div class="small muted">${esc(s.hint)}</div></div>
      </form>`;
    })
    .join("");

  const messagesHtml = messages.messages
    .map((m) => {
      const text = fillMsg(m.text, { ...vars, link: links.share(m.channel) });
      return `<div class="card">
        <div class="row" style="justify-content:space-between"><strong>${esc(m.label)}</strong>
          <button class="small" data-copy="${attr(text)}">copy</button></div>
        <p class="msg">${esc(text)}</p>
        <p class="small muted">opens: ${allByKey[`link:${m.channel}`] ?? 0} total · ${recentByKey[`link:${m.channel}`] ?? 0} last ${stats.days} days</p>
      </div>`;
    })
    .join("");

  const postersHtml = designs
    .map(
      (d) => `<a class="poster" href="${posterImagePath(amb.school, d)}" target="_blank" rel="noopener">
        <img loading="lazy" src="${posterImagePath(amb.school, d)}" alt="${attr(posterName(d))} poster">
        <div>${esc(posterName(d).toLowerCase())}</div></a>`,
    )
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
    <p class="small muted">smooth · ${esc(school.name.toLowerCase())}</p>
    <h1>hey ${esc(firstName(amb.name))}</h1>
    <p class="muted">your page. nobody else sees this link. ${esc(amb.title)}.</p>
    <p class="noprint"><a class="btn small" href="smooth://ambassador?code=${attr(amb.token)}">open in the smooth app</a> <span class="small muted">daily reminders + today's post, inside smooth</span></p>
    ${flash ? `<p class="ok">${esc(flash)}</p>` : ""}
    <nav class="tabs noprint">
      <a href="#numbers">numbers</a><a href="#messages">messages</a><a href="#drop">log a drop</a><a href="#posters">posters</a><a href="#feedback">feedback</a><a href="#start">checklist</a>
    </nav>

    <h2 id="numbers">your numbers</h2>
    <div class="card">
      <table>
        <tr><td>your link opens</td><td class="num"><strong>${stats.linkOpens + stats.posterOpens}</strong> <span class="muted small">· ${stats.linkOpensRecent + stats.posterOpensRecent} last ${stats.days}d</span></td></tr>
        <tr><td>${esc(school.name.toLowerCase())} poster scans</td><td class="num"><strong>${stats.schoolScansTotal}</strong> <span class="muted small">· ${stats.schoolScansRecent} last ${stats.days}d</span></td></tr>
        <tr><td>posters you've put up</td><td class="num"><strong>${stats.drops}</strong></td></tr>
        <tr><td>posts you've logged</td><td class="num"><strong>${stats.posts}</strong></td></tr>
      </table>
      <p class="small muted">opens count link taps, repeats included, not people. <a href="/">school leaderboard</a></p>
    </div>

    <h2 id="messages">messages, ready to paste</h2>
    <p class="muted small">each one carries your own link, so opens show up here. change the words to sound like you.</p>
    ${messagesHtml}
    <details><summary>posting tips</summary><ul class="small">${messages.posting_tips.map((t) => `<li>${esc(t)}</li>`).join("")}</ul></details>

    <h2 id="drop">log a poster drop</h2>
    <form method="post" action="${base}/drop" class="card">
      <label>which design</label>
      <div class="chips">${dropChips}</div>
      <label>how many copies</label>
      <div class="row">${[1, 2, 3, 5, 10].map((n) => `<label class="chip"><input type="radio" name="copies" value="${n}" ${n === 1 ? "checked" : ""}>${n}</label>`).join("")}</div>
      <label>where (optional)</label>
      <input name="place" placeholder="e.g. library 1st floor, dorm lobby" maxlength="120" autocomplete="off">
      <p><button type="submit">log it</button></p>
    </form>

    <h2>log a post</h2>
    <form method="post" action="${base}/post" class="card">
      <label>where</label>
      <div class="chips">${channelChips}</div>
      <label>which chat / detail (optional)</label>
      <input name="place" placeholder="e.g. class of '28 gc" maxlength="120" autocomplete="off">
      <p><button type="submit">log it</button></p>
    </form>

    <h3>recent</h3>
    ${activityHtml}

    <h2 id="posters">${esc(school.name.toLowerCase())} posters</h2>
    <p class="muted small">tap to open, then print. black and white is fine. these codes count for ${esc(school.name.toLowerCase())}. <a href="${base}/stickers">your own qr stickers</a> count for you too.</p>
    <div class="grid">${postersHtml}</div>

    <h2 id="feedback">tell the founders something</h2>
    <form method="post" action="${base}/feedback" class="card">
      <textarea name="body" placeholder="what's confusing, what's broken, what people said, what you'd change" maxlength="2000" required></textarea>
      <p><button type="submit">send</button></p>
      <p class="small muted">goes straight to olisa and marco. honest beats nice.</p>
    </form>

    <h2 id="start">checklist</h2>
    <div class="card">${checklistHtml}</div>

    <h2>reminders</h2>
    <div class="card">
      <p class="small">we send a short update about every two weeks, by text, from a real phone. ${paused ? `<strong>paused until ${esc(String(amb.paused_until).slice(0, 10))}.</strong>` : ""}</p>
      <form method="post" action="${base}/pause" class="row">
        <button class="small ghost" name="weeks" value="4">pause 4 weeks</button>
        <button class="small ghost" name="weeks" value="12">pause the semester</button>
        ${paused ? `<button class="small" name="weeks" value="0">resume</button>` : ""}
      </form>
    </div>
    <p class="small muted">questions: text marco at +1 202 320 3802.</p>`;

  return layout({ title: `smooth · ${firstName(amb.name)}`, body });
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
    <p class="noprint"><a href=".">← back</a></p>
    <h1>your qr stickers</h1>
    <p class="muted small noprint">print this page, cut them out, stick one over the code on a poster (or next to it). scans count for ${esc(SCHOOLS[amb.school].name.toLowerCase())} <em>and</em> for you. <button class="small" onclick="print()">print</button></p>
    <div class="grid" style="grid-template-columns:repeat(auto-fill,minmax(110px,1fr))">${cards}</div>`;
  return layout({ title: "smooth · stickers", body });
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
          <tr><td>did</td><td>${a.drops} posters · ${a.posts} posts · checklist ${a.checklistDone}/${checklist.steps.length} · last ${esc(ago(a.lastActivity))}</td></tr>
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

  const body = `
    <p class="small muted">smooth · founders</p>
    <h1>ambassadors</h1>
    <p class="muted small">private. this url is the key, don't share it. <a href="${base}/export.json">export json</a> · <a href="/">public dashboard</a></p>
    ${flash ? `<p class="ok">${esc(flash)}</p>` : ""}
    <nav class="tabs">
      <a href="#roster">roster</a><a href="#digest">digest</a><a href="#moments">campus moments</a><a href="#feedback">feedback</a><a href="#perf">performance</a><a href="#add">add</a>
    </nav>
    ${createdHtml}

    <h2 id="perf">by school <span class="muted small">last ${stats.days} days</span></h2>
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

    <h2 id="roster">roster <span class="muted small">${stats.ambassadors.length}</span></h2>
    ${rosterRows || `<p class="muted">nobody yet. add your first friend below.</p>`}

    <h2 id="add">add an ambassador</h2>
    <form method="post" action="${base}/add" class="card">
      <label>name</label><input name="name" required maxlength="80" autocomplete="off">
      <label>school</label><select name="school">${Object.entries(SCHOOLS).map(([k, s]) => `<option value="${attr(k)}">${esc(s.name)}</option>`).join("")}</select>
      <label>contact (phone is best, enables one-tap texts)</label><input name="contact" maxlength="120" autocomplete="off" inputmode="tel">
      <label>notes (optional)</label><input name="notes" maxlength="500" autocomplete="off">
      <p><button>add and get their link</button></p>
    </form>

    <h2 id="digest">two-week digest</h2>
    <p class="muted small">built from real numbers right now. tap "text it", send from your phone, then "mark sent". anyone paused or silent after two digests is skipped automatically.</p>
    ${digestRows || `<p class="muted">add ambassadors first.</p>`}

    <h2 id="moments">campus moments</h2>
    <p class="muted small">pick the moment, the texts fill in per person. these go out even to the quiet ones (never to paused).</p>
    <select id="moment" onchange="applyMoment()" style="margin-bottom:8px">${momentOptions}</select>
    ${momentRows || `<p class="muted">add ambassadors first.</p>`}

    <h2 id="feedback">feedback <span class="muted small">${stats.feedback.filter((f) => !f.seen).length} new</span></h2>
    ${feedbackHtml}

    <h2>activity</h2>
    ${activityHtml}`;

  const script = `
    var MOMENTS=${scriptJSON(momentData)};
    function applyMoment(){var k=document.getElementById('moment').value;document.querySelectorAll('[data-moment-card]').forEach(function(c){var id=c.getAttribute('data-id');var m=MOMENTS[id]&&MOMENTS[id][k];if(!m)return;c.querySelector('.msg').textContent=m.text;var s=c.querySelector('[data-send]');s.innerHTML='';if(m.sms){var a=document.createElement('a');a.className='btn small';a.href=m.sms;a.textContent='text it';s.appendChild(a);s.appendChild(document.createTextNode(' '))}var b=document.createElement('button');b.className='small ghost';b.setAttribute('data-copy',m.text);b.textContent='copy';s.appendChild(b);c.querySelector('[data-kind]').value='moment:'+k})}
    applyMoment();`;

  return layout({ title: "smooth · founders", body, script });
}
