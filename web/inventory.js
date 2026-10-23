'use strict';
const list = document.querySelector('#repositories');
const notice = document.querySelector('#notice');
const filter = document.querySelector('#filter');
const refresh = document.querySelector('#refresh');
let inventory = null;

function formatted(value) {
  if (!value) return 'Unavailable';
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? 'Unavailable'
    : new Intl.DateTimeFormat(undefined, { year:'numeric', month:'short', day:'numeric', hour:'2-digit', minute:'2-digit' }).format(parsed);
}
function el(name, className, value) {
  const item = document.createElement(name);
  if (className) item.className = className;
  if (value !== undefined) item.textContent = value;
  return item;
}
function render() {
  list.replaceChildren();
  if (!inventory) return;
  const search = filter.value.trim().toLowerCase();
  let shown = 0;
  for (const repo of inventory.repositories) {
    const match = repo.name.toLowerCase().includes(search);
    const tags = match ? repo.tags : repo.tags.filter(tag => tag.tag.toLowerCase().includes(search));
    if (!match && !tags.length) continue;
    shown++;
    const card = el('article', 'repo');
    const head = el('div','repo-head');
    head.append(el('div','repo-title',repo.name), el('div','repo-meta',tags.length + (tags.length === 1 ? ' tag':' tags')));
    card.append(head);
    if (tags.length) {
      const wrapper = el('div','table-wrap');
      const table = el('table');
      const thead = el('thead');
      const titles = el('tr');
      for (const title of ['Tag / version','Tag updated¹','Image built²','Digest']) titles.append(el('th','',title));
      thead.append(titles); table.append(thead);
      const tbody = el('tbody');
      for (const tag of tags) {
        const row = el('tr');
        const label = el('td'); label.append(el('span','tag',tag.tag)); row.append(label);
        row.append(el('td',tag.tag_updated_at?'':'missing',formatted(tag.tag_updated_at)));
        row.append(el('td',tag.built_at?'':'missing',formatted(tag.built_at)));
        const digestCell = el('td');
        const digest = el('code','',tag.digest ? tag.digest.slice(0,23) + '…' : 'Unavailable');
        if (tag.digest) digest.title = tag.digest;
        digestCell.append(digest); row.append(digestCell);
        tbody.append(row);
      }
      table.append(tbody);wrapper.append(table);card.append(wrapper);
    } else card.append(el('div','no-tags','No tags found'));
    const foot=el('div','repo-foot');
    foot.append(el('span','', 'Last tagged: '+formatted(repo.updated_at)),el('span','','Read-only'));
    card.append(foot);list.append(card);
  }
  notice.classList.toggle('hidden', shown > 0);
  if (!shown) notice.textContent = search ? 'No matching repositories or tags.' : 'No images have been pushed yet.';
}
async function getHealth() {
  const dot = document.querySelector('#status-dot');
  const label = document.querySelector('#status-text');
  try {
    const response = await fetch('/healthz',{cache:'no-store'});
    const state = await response.json();
    const healthy = response.ok && state.status === 'ok';
    dot.className = 'dot '+(healthy?'ok':'bad');
    label.textContent = healthy ? 'Registry healthy' : 'Registry degraded';
  } catch { dot.className='dot bad'; label.textContent='Health unavailable'; }
}
async function load() {
  refresh.disabled=true;
  notice.textContent='Loading inventory…';
  notice.classList.remove('hidden','error');
  try {
    const response = await fetch('/api/inventory',{cache:'no-store'});
    if (!response.ok) throw Error('Inventory unavailable (HTTP '+response.status+')');
    inventory=await response.json();
    document.querySelector('#repo-count').textContent=inventory.repository_count;
    document.querySelector('#tag-count').textContent=inventory.tag_count;
    document.querySelector('#last-checked').textContent=formatted(inventory.generated_at);
    render();
  } catch(error) {
    inventory=null;list.replaceChildren();notice.textContent=error.message || 'Inventory unavailable';notice.classList.add('error');
  } finally { refresh.disabled=false; }
  await getHealth();
}
filter.addEventListener('input',render);
refresh.addEventListener('click',load);
load();
