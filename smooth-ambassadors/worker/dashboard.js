// The public dashboard, byte for byte as the live site served it on
// 2026-11-10 (minus the bot-check script Cloudflare injects per request).
// It draws itself from /api/stats every 15 seconds, so the page and that
// route's JSON shape are one contract: change neither without the other.
// When merging into the Sites repository, the live worker's own copy wins.
export const DASHBOARD_HTML = String.raw`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Smooth Poster Scans</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f5f7fa;color:#17243b;font:16px system-ui,sans-serif}
main{max-width:1080px;margin:auto;padding:48px 22px}.tag{font-size:.8rem;letter-spacing:.15em;color:#435a92;font-weight:800}
h1{font-size:clamp(2rem,6vw,3.5rem);line-height:1.08;margin:12px 0}p{line-height:1.5;color:#475569}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:26px 0}
.card,.panel{background:white;border:1px solid #dde4ef;border-radius:16px;padding:20px}
.card strong{display:block;font-size:2rem;margin-top:8px}
.toolbar{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin-bottom:16px}
select,button{font:inherit}select{padding:10px;border:1px solid #ccd5e2;border-radius:8px;background:white}
#status{font-size:.85rem;color:#64748b}table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:15px 8px;border-bottom:1px solid #e4eaf2}th:last-child,td:last-child{text-align:right}
td:last-child{font-weight:800}.poster{border:0;padding:0;background:transparent;color:#3154a0;text-align:left;text-decoration:underline;text-underline-offset:4px;cursor:pointer}
dialog{border:0;border-radius:16px;padding:18px;width:min(92vw,720px);max-height:94vh;box-shadow:0 20px 80px #0005}
dialog::backdrop{background:#122139b8}.modal-top{display:flex;align-items:center;justify-content:space-between;gap:16px}
h2{font-size:1.1rem}.close{border:1px solid #ccd5e2;background:white;border-radius:8px;padding:8px 14px;cursor:pointer}
#preview{display:block;max-width:100%;max-height:75vh;margin:auto;object-fit:contain}
@media(max-width:650px){.cards{grid-template-columns:repeat(2,1fr)}main{padding:30px 14px}.panel{padding:12px}th,td{font-size:.9rem}}
</style></head><body><main>
<div class="tag">SMOOTH FOR STUDENTS</div><h1>Poster scan performance</h1>
<p>Compare schools and poster designs. Click a poster name to see its school edition.</p>
<div class="cards" id="cards"></div>
<section class="panel"><div class="toolbar"><label for="school">School</label><select id="school">
<option value="all">All schools</option><option value="upenn">UPenn</option><option value="umiami">UMiami</option><option value="uva">UVA</option><option value="case-western">Case Western</option><option value="clark">Clark University</option>
</select><span id="status" role="status">Loading counts…</span></div>
<table><thead><tr><th scope="col">Poster design</th><th scope="col">School</th><th scope="col">Link opens</th></tr></thead><tbody id="rows"></tbody></table></section>
<p>Counts include repeat link opens and verification scans. Updates every 15 seconds.</p>
</main><dialog id="modal"><div class="modal-top"><h2 id="preview-title"></h2><button class="close" id="close">Close</button></div><img id="preview" alt=""></dialog>
<script>
const schoolNames = {upenn:'UPenn',umiami:'UMiami',uva:'UVA','case-western':'Case Western',clark:'Clark University'};
const filter = document.querySelector('#school');
const query = new URLSearchParams(location.search).get('school');
if (query === 'all' || Object.hasOwn(schoolNames, query)) filter.value = query;
let rows = [];
function render() {
  const cards = document.querySelector('#cards');
  cards.replaceChildren();
  for (const [id, name] of Object.entries(schoolNames)) {
    const card = document.createElement('div'); card.className = 'card';
    const label = document.createElement('span'); label.textContent = name;
    const total = document.createElement('strong'); total.textContent = rows.filter(row => row.school === id).reduce((sum,row) => sum + row.total,0);
    card.append(label,total);cards.append(card);
  }
  const tbody = document.querySelector('#rows');tbody.replaceChildren();
  for (const row of rows.filter(row => filter.value === 'all' || row.school === filter.value)) {
    const tr = document.createElement('tr');
    const name = document.createElement('td');
    const button = document.createElement('button');button.className = 'poster';button.textContent = row.name;
    button.addEventListener('click',() => {
      document.querySelector('#preview-title').textContent = row.name + ' · ' + row.schoolName;
      const img = document.querySelector('#preview');img.src = '/posters/' + row.school + '/' + row.poster + '.jpg';img.alt = row.name + ' poster for ' + row.schoolName;
      document.querySelector('#modal').showModal();
    });
    name.append(button);
    const school = document.createElement('td');school.textContent = row.schoolName;
    const count = document.createElement('td');count.textContent = row.total;
    tr.append(name,school,count);tbody.append(tr);
  }
}
async function refresh() {
  try {
    const response = await fetch('/api/stats',{cache:'no-store'});
    if (!response.ok) throw new Error('Unable to load counts');
    rows = (await response.json()).rows;render();
    document.querySelector('#status').textContent = 'Updated ' + new Date().toLocaleTimeString();
  } catch (error) {
    document.querySelector('#status').textContent = 'Unable to refresh counts. Retrying shortly.';
  }
}
filter.addEventListener('change',() => {const url = new URL(location);url.searchParams.set('school',filter.value);history.replaceState(null,'',url);render();});
document.querySelector('#close').addEventListener('click',() => document.querySelector('#modal').close());
document.querySelector('#modal').addEventListener('click',event => {if (event.target === event.currentTarget) event.currentTarget.close();});
refresh();setInterval(refresh,15000);
</script></body></html>`;
