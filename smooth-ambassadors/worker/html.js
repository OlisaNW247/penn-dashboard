// Tiny HTML helpers. Black on white, system font, lowercase, phone first.

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

export const CSS = `
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;padding:16px;max-width:680px;margin-inline:auto;font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#111;background:#fff}
h1,h2,h3{font-weight:700;letter-spacing:-.01em;margin:0 0 .4em}
h1{font-size:26px}h2{font-size:19px;margin-top:1.4em}h3{font-size:16px}
p{margin:.4em 0}
a{color:#111}
.muted{color:#666;font-weight:400}
.small{font-size:13px}
.card{border:1.5px solid #111;border-radius:14px;padding:14px;margin:12px 0}
table{width:100%;border-collapse:collapse}
td,th{padding:6px 4px;text-align:left;border-bottom:1px solid #e5e5e5;vertical-align:top}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:0}
button,.btn{appearance:none;border:1.5px solid #111;background:#111;color:#fff;border-radius:999px;padding:10px 16px;font:inherit;font-weight:600;cursor:pointer;min-height:44px;text-decoration:none;display:inline-flex;align-items:center;justify-content:center}
button.ghost,.btn.ghost{background:#fff;color:#111}
button.small,.btn.small{min-height:36px;padding:6px 12px;font-size:14px}
button:active{transform:scale(.98)}
input,select,textarea{font:inherit;border:1.5px solid #111;border-radius:10px;padding:10px 12px;width:100%;min-height:44px;background:#fff;color:#111}
textarea{min-height:88px}
label{display:block;font-size:13px;color:#444;margin:10px 0 4px}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip{border:1.5px solid #111;border-radius:999px;padding:8px 12px;background:#fff;font-size:14px;min-height:40px}
.chip input{display:none}
.chip:has(input:checked){background:#111;color:#fff}
.msg{white-space:pre-wrap;background:#f6f6f6;border-radius:10px;padding:12px;font-size:15px}
.ok{color:#0a7a2f}
.check{display:flex;gap:10px;align-items:flex-start;padding:8px 0;border-bottom:1px solid #eee}
.check input{width:22px;height:22px;min-height:0;margin-top:2px;flex:none}
.check .done{text-decoration:line-through;color:#888}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px}
.poster{border:1px solid #ddd;border-radius:10px;overflow:hidden;text-align:center;font-size:13px}
.poster img{width:100%;aspect-ratio:8.5/11;object-fit:cover;background:#f2f2f2;display:block}
.poster div{padding:6px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:#111;color:#fff;padding:10px 16px;border-radius:999px;font-size:14px;opacity:0;transition:opacity .2s;pointer-events:none}
.toast.show{opacity:1}
nav.tabs{display:flex;gap:6px;overflow-x:auto;padding-bottom:6px;margin:8px -16px 0;padding-inline:16px}
nav.tabs a{white-space:nowrap;border:1.5px solid #111;border-radius:999px;padding:6px 12px;text-decoration:none;font-size:14px}
details summary{cursor:pointer;font-weight:600;padding:8px 0}
.qr{width:100%;max-width:120px;height:auto;display:block;margin:0 auto 4px}
@media print{button,.btn,nav,.noprint{display:none!important}body{padding:0}.card{break-inside:avoid;border-color:#000}}
`;

export const COPY_JS = `
function toast(t){var e=document.getElementById('toast');e.textContent=t;e.classList.add('show');setTimeout(function(){e.classList.remove('show')},1400)}
async function copyText(t){try{await navigator.clipboard.writeText(t);toast('copied')}catch(e){var ta=document.createElement('textarea');ta.value=t;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove();toast('copied')}}
document.addEventListener('click',function(ev){var b=ev.target.closest('[data-copy]');if(b){ev.preventDefault();copyText(b.getAttribute('data-copy'))}});
`;

export function layout({ title, body, head = "", script = "" }) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<title>${esc(title)}</title>
<style>${CSS}</style>${head}
</head><body>
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
