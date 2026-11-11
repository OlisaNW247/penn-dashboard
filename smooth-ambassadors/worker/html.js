// Tiny HTML helpers and the shared page shell. Smooth's look, lowercase, phone first.

export function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[c]);
}

export function attr(s) {
  return esc(s);
}

// Smooth's look, taken from the iOS app: white paper, warm surfaces, six accents
// used only as FILLS (text beside an accent uses its darker "ink" partner), a
// mono face for small labels, lowercase copy. Dark mode follows the system
// ("after sunset"). Fonts are served by this Worker (worker/fonts.js).
export const CSS = `
@font-face{font-family:"Familjen Grotesk";src:url(/a/_fonts/familjen-grotesk.woff2) format("woff2");font-weight:400 700;font-display:swap}
@font-face{font-family:"Inter";src:url(/a/_fonts/inter.woff2) format("woff2");font-weight:400 700;font-display:swap}
@font-face{font-family:"Space Mono";src:url(/a/_fonts/space-mono.woff2) format("woff2");font-weight:400;font-display:swap}
@font-face{font-family:"Space Mono";src:url(/a/_fonts/space-mono-bold.woff2) format("woff2");font-weight:700;font-display:swap}
:root{color-scheme:light dark;
--paper:#fff;--surface:#F2E5C9;--rule:#D9C9A6;--ink:#1B1714;--muted:#7C7060;--on:#1B1714;
--tomato:#F07256;--marigold:#F7A844;--lemon:#F5D353;--teal:#40B3A5;--cobalt:#699AE7;--grape:#AF85F0;
--tomato-ink:#B63B23;--marigold-ink:#985700;--lemon-ink:#746400;--teal-ink:#176D65;--cobalt-ink:#345EA8;--grape-ink:#7044A6;
--display:"Familjen Grotesk",system-ui,-apple-system,"Segoe UI",sans-serif;
--body:"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
--mono:"Space Mono",ui-monospace,SFMono-Regular,Menlo,monospace;--c:var(--teal);--ci:var(--teal-ink)}
@media(prefers-color-scheme:dark){:root{--paper:#0B1020;--surface:#171D31;--rule:#303A59;--ink:#F8F1E5;--muted:#AEB8CF;
--tomato-ink:#F59A85;--marigold-ink:#FBCB75;--lemon-ink:#F9E889;--teal-ink:#76D4C9;--cobalt-ink:#A8C4F5;--grape-ink:#D0B2F7}}
.t-tomato{--c:var(--tomato);--ci:var(--tomato-ink)}.t-marigold{--c:var(--marigold);--ci:var(--marigold-ink)}
.t-lemon{--c:var(--lemon);--ci:var(--lemon-ink)}.t-teal{--c:var(--teal);--ci:var(--teal-ink)}
.t-cobalt{--c:var(--cobalt);--ci:var(--cobalt-ink)}.t-grape{--c:var(--grape);--ci:var(--grape-ink)}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;scroll-behavior:smooth;scroll-padding-top:12px}
body{margin:0;padding:16px 16px 48px;max-width:720px;margin-inline:auto;font:16px/1.5 var(--body);color:var(--ink);background:var(--paper);overflow-wrap:anywhere}
body.wide{max-width:1040px}
h1,h2,h3{font-family:var(--display);font-weight:700;letter-spacing:-.02em;margin:0 0 .4em;line-height:1.1}
h1{font-size:34px;margin-top:20px}h3{font-size:18px;margin-top:1em}
p{margin:.4em 0}
a{color:var(--ink);text-underline-offset:3px}
.muted{color:var(--muted);font-weight:400}
.small{font-size:13px}
.mono{font-family:var(--mono)}
.top{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:4px 0 8px}
.mark{display:inline-block;font:700 30px/1 var(--display);letter-spacing:-.03em}
.mark svg{display:block;width:76px;height:9px;margin-top:3px;overflow:visible}
.who{font:400 12px var(--mono);color:var(--muted);padding-bottom:4px}
.sec{border-radius:22px;padding:18px 16px;margin:16px 0;background:var(--surface);border:1px solid var(--rule)}
@supports (background:color-mix(in srgb,red 10%,white)){.sec{background:color-mix(in srgb,var(--c) 14%,var(--paper));border-color:color-mix(in srgb,var(--c) 32%,var(--paper))}}
.sec>h2,.sh{font:700 12px/1.3 var(--mono);letter-spacing:.06em;color:var(--ci);margin:0 0 12px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.sec>h2::before{content:"";width:10px;height:10px;border-radius:50%;background:var(--c);flex:none}
.sec>h2 .muted{font-weight:400}
.card{background:var(--paper);border:1px solid var(--rule);border-radius:18px;padding:14px;margin:10px 0}
.sec>.card:first-of-type{margin-top:0}
details.card>summary{list-style:none}
details.card>summary::-webkit-details-marker{display:none}
table{width:100%;border-collapse:collapse}
td,th{padding:7px 4px;text-align:left;border-bottom:1px solid var(--rule);vertical-align:top}
th{font:700 11px var(--mono);color:var(--muted);white-space:nowrap}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:0}
button,.btn{appearance:none;border:0;background:var(--c,var(--tomato));color:var(--on);border-radius:999px;padding:10px 18px;font:600 15px/1.2 var(--body);cursor:pointer;min-height:44px;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;gap:6px}
button.ghost,.btn.ghost{background:transparent;color:var(--ink);box-shadow:inset 0 0 0 1.5px var(--rule)}
button.small,.btn.small{min-height:40px;padding:6px 14px;font-size:14px}
button:active,.btn:active,.jump:active{transform:scale(.98)}
button:disabled{opacity:.55;cursor:default}
:focus-visible{outline:3px solid var(--cobalt);outline-offset:2px}
input,select,textarea{font:inherit;border:1.5px solid var(--rule);border-radius:14px;padding:10px 12px;width:100%;min-height:44px;background:var(--paper);color:var(--ink)}
textarea{min-height:92px;resize:vertical}
label{display:block;font:400 12px var(--mono);color:var(--muted);margin:12px 0 5px}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip{position:relative;display:inline-flex;align-items:center;border:1.5px solid var(--rule);border-radius:999px;padding:8px 14px;background:var(--paper);font:400 14px var(--body);min-height:44px;margin:0;color:var(--ink);cursor:pointer}
.chip input{position:absolute;opacity:0;width:1px;height:1px;min-height:0;pointer-events:none}
.chip:has(input:checked){background:var(--c,var(--teal));border-color:transparent;color:var(--on);font-weight:600}
.chip:has(input:focus-visible){outline:3px solid var(--cobalt);outline-offset:2px}
.msg{white-space:pre-wrap;background:var(--surface);border-radius:14px;padding:12px;font-size:15px;margin:8px 0}
.ok{font:700 13px var(--mono);padding:10px 14px;border-radius:999px;background:var(--teal);color:var(--on);display:inline-block}
.err{color:var(--tomato-ink)}
.check{display:flex;gap:12px;align-items:flex-start;padding:10px 0;border-bottom:1px solid var(--rule)}
.check:last-child{border-bottom:0}
.check input{width:24px;height:24px;min-height:0;margin-top:1px;flex:none;accent-color:var(--teal)}
.check .done{text-decoration:line-through;color:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--ink);color:var(--paper);padding:10px 18px;border-radius:999px;font:400 13px var(--mono);opacity:0;transition:opacity .2s;pointer-events:none}
.toast.show{opacity:1}
nav.tabs{display:flex;gap:6px;overflow-x:auto;padding:4px 16px 8px;margin:6px -16px 0;scrollbar-width:none}
nav.tabs a{white-space:nowrap;border-radius:999px;padding:8px 14px;text-decoration:none;font:400 12px var(--mono);box-shadow:inset 0 0 0 1.5px var(--rule);min-height:36px;display:inline-flex;align-items:center}
.qr{width:100%;max-width:120px;height:auto;display:block;margin:0 auto 4px;background:#fff}
/* the three big doors under the header */
.jumps{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:14px 0 4px}
.jump{background:var(--c);color:var(--on);border-radius:22px;padding:14px 12px 12px;text-decoration:none;display:flex;flex-direction:column;gap:3px;min-height:148px;position:relative}
.jump .gl{width:38px;height:38px;border-radius:12px;background:rgba(255,255,255,.55);display:flex;align-items:center;justify-content:center;margin-bottom:auto}
.jump .gl svg{width:22px;height:22px}
.jump b{font:700 17px/1.1 var(--display);letter-spacing:-.01em;margin-top:10px}
.jump span{font-size:12px;line-height:1.3}
.jump em{position:absolute;top:12px;right:12px;font:700 10px var(--mono);font-style:normal;background:rgba(255,255,255,.55);border-radius:999px;padding:2px 7px}
/* big friendly numbers */
.stats{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.stat{border-radius:18px;padding:14px;background:var(--surface);color:var(--ink)}
@supports (background:color-mix(in srgb,red 10%,white)){.stat{background:color-mix(in srgb,var(--c) 26%,var(--paper))}}
.stat b{display:block;font:700 40px/1 var(--display);letter-spacing:-.03em}
.stat span{display:block;font:400 11px/1.3 var(--mono);margin-top:6px;color:var(--ink)}
.stat small{font:400 11px var(--mono);color:var(--muted)}
/* posters */
.pgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.pcard{background:var(--paper);border:1px solid var(--rule);border-radius:18px;overflow:hidden;display:flex;flex-direction:column}
.pcard img{width:100%;aspect-ratio:8.5/11;object-fit:cover;background:var(--surface);display:block}
.pcard .pb{padding:10px;display:flex;flex-direction:column;gap:8px;flex:1}
.pcard .pn{font:600 14px/1.25 var(--display)}
.pcard .ps{font:400 11px var(--mono);color:var(--muted)}
.pcard .btn,.pcard button{width:100%;min-height:40px;font-size:13px;padding:6px 10px}
.pcard .hint{font-size:11px;line-height:1.3;color:var(--muted);margin:-2px 0 0}
.preview{display:none;max-width:100%;max-height:220px;border-radius:14px;margin:10px 0;border:1px solid var(--rule)}
.file{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.file input{position:absolute;opacity:0;width:1px;height:1px;min-height:0;pointer-events:none}
.file:has(input:focus-visible) .btn{outline:3px solid var(--cobalt);outline-offset:2px}
.thumb{display:block;max-width:200px;max-height:200px;border-radius:14px;border:1px solid var(--rule);margin:8px 0;background:var(--surface)}
details summary{cursor:pointer;font-weight:600;padding:8px 0;min-height:44px}
@media(max-width:380px){.jump b{font-size:15px}.jump{padding:12px 10px}.stat b{font-size:34px}}
@media print{:root{color-scheme:light;--paper:#fff;--surface:#fff;--ink:#000;--muted:#444;--rule:#999}
body{background:#fff;color:#000;padding:0}
button,.btn,nav,.noprint,.jumps,.top{display:none!important}
.sec,.card{background:#fff!important;border-color:#000!important;break-inside:avoid}}
`;

export const COPY_JS = `
function toast(t){var e=document.getElementById('toast');e.textContent=t;e.classList.add('show');setTimeout(function(){e.classList.remove('show')},1400)}
async function copyText(t){try{await navigator.clipboard.writeText(t);toast('copied')}catch(e){var ta=document.createElement('textarea');ta.value=t;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove();toast('copied')}}
document.addEventListener('click',function(ev){var b=ev.target.closest('[data-copy]');if(b){ev.preventDefault();copyText(b.getAttribute('data-copy'))}});
`;

// "smooth" with its squiggle, and who the page is for.
export function siteHeader(who) {
  return `<header class="top" id="top"><div class="mark" aria-label="smooth"><span>smooth</span><svg viewBox="0 0 76 9" aria-hidden="true"><path d="M2 5.5C8 0.5 13 0.5 19 4.5S30 8.5 38 4.5 51 0.5 57 4.5 68 7.5 74 3" fill="none" stroke="var(--tomato)" stroke-width="3.2" stroke-linecap="round"/></svg></div>${who ? `<div class="who">${esc(who)}</div>` : ""}</header>`;
}

export function layout({ title, body, head = "", script = "", wide = false, who = "" }) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="referrer" content="no-referrer">
<meta name="color-scheme" content="light dark">
<title>${esc(title)}</title>
<style>${CSS}</style>${head}
</head><body${wide ? ' class="wide"' : ""}>
${siteHeader(who)}
${body}
<div id="toast" class="toast" role="status"></div>
<script>${COPY_JS}${script}</script>
</body></html>`;
}

export function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "x-robots-tag": "noindex",
    },
  });
}
