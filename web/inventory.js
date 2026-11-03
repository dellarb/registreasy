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
async function callDelete(body) {
  const response = await fetch('/api/delete', {
    method: 'POST', cache: 'no-store', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-Registreasy-Action': 'delete' },
    body: JSON.stringify(body),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw Error(payload.message || payload.error || ('HTTP ' + response.status));
  return payload;
}
function describe(plan) {
  const tagList = plan.tags.join(', ');
  const scope = plan.scope === 'repository'
    ? 'the whole repository ' + plan.repository + ' (' + plan.tags.length + ' tags)'
    : plan.repository + ':' + plan.tag;
  const extra = plan.tags.length > 1 && plan.scope === 'tag'
    ? '\n\nThis manifest is also tagged: ' + tagList + '. Those tags will be removed too.' : '';
  return 'Delete ' + scope + '?\n\nRemoves manifest(s): ' + plan.digests.length + '.' + extra
    + '\nTags affected: ' + tagList
    + '\n\nDisk space is freed only after garbage collection.';
}
async function deleteFlow(repo, tag) {
  notice.classList.add('hidden');
  try {
    const body = tag ? { repo, tag } : { repo };
    const plan = await callDelete({ ...body, preview: true });
    if (!window.confirm(describe(plan))) return;
    const done = await callDelete(body);
    notice.textContent = 'Deleted ' + (done.scope === 'repository' ? done.repository : done.repository + ':' + done.tag) + '.';
    notice.classList.remove('error');
    notice.classList.remove('hidden');
    await load();
  } catch (error) {
    notice.textContent = 'Delete failed: ' + error.message;
    notice.classList.add('error');
    notice.classList.remove('hidden');
  }
}
function button(label, className, onClick) {
  const b = el('button', className, label);
  b.type = 'button';
  b.addEventListener('click', onClick);
  return b;
}
function render() {
  list.replaceChildren();
  if (!inventory) return;
  const search = filter.value.trim().toLowerCase();
  const canDelete = inventory.can_delete === true;
  let shown = 0;
  for (const repo of inventory.repositories) {
    const match = repo.name.toLowerCase().includes(search);
    const tags = match ? repo.tags : repo.tags.filter(tag => tag.tag.toLowerCase().includes(search));
    if (!match && !tags.length) continue;
    shown++;
    const card = el('article', 'repo');
    const head = el('div','repo-head');
    const actions = el('div','repo-actions');
    actions.append(el('div','repo-meta',tags.length + (tags.length === 1 ? ' tag':' tags')));
    if (canDelete) actions.append(button('Delete repository', 'danger', () => deleteFlow(repo.name, null)));
    head.append(el('div','repo-title',repo.name), actions);
    card.append(head);
    if (tags.length) {
      const wrapper = el('div','table-wrap');
      const table = el('table');
      const thead = el('thead');
      const titles = el('tr');
      for (const title of ['Tag / version','Tag updated¹','Image built²','Digest']) titles.append(el('th','',title));
      if (canDelete) titles.append(el('th','','')); 
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
        if (canDelete) {
          const cell = el('td');
          cell.append(button('Delete', 'danger small', () => deleteFlow(repo.name, tag.tag)));
          row.append(cell);
        }
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
