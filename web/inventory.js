'use strict';
const list = document.querySelector('#repositories');
const notice = document.querySelector('#notice');
const filter = document.querySelector('#filter');
const refresh = document.querySelector('#refresh');
let inventory = null;
// Session lives only in this page's memory: reloading or signing out clears it.
let session = null; // { mode: 'pull'|'push', auth: 'Basic …' }
const signin = document.querySelector('#signin');
const app = document.querySelector('#app');
const signout = document.querySelector('#signout');
const signinForm = document.querySelector('#signin-form');
const signinError = document.querySelector('#signin-error');
const signinSubmit = document.querySelector('#signin-submit');
let mode = 'pull';

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
    method: 'POST', cache: 'no-store', credentials: 'omit',
    headers: { 'Content-Type': 'application/json', 'X-Registreasy-Action': 'delete', Authorization: session.auth },
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
function applyInventory() {
  document.querySelector('#repo-count').textContent=inventory.repository_count;
  document.querySelector('#tag-count').textContent=inventory.tag_count;
  document.querySelector('#last-checked').textContent=formatted(inventory.generated_at);
  render();
}
async function load() {
  if (!session) return showSignin();
  refresh.disabled=true;
  notice.textContent='Loading inventory…';
  notice.classList.remove('hidden','error');
  try {
    const response = await fetch('/api/inventory',{cache:'no-store', credentials:'omit', headers: {Authorization: session.auth}});
    if (response.status === 401) { showSignin('That password was not accepted for ' + session.user + '.'); return; }
    if (!response.ok) throw Error('Inventory unavailable (HTTP '+response.status+')');
    inventory=await response.json();
    applyInventory();
  } catch(error) {
    inventory=null;list.replaceChildren();notice.textContent=error.message || 'Inventory unavailable';notice.classList.add('error');
  } finally { refresh.disabled=false; }
  await getHealth();
}
function setMode(next) {
  mode = next;
  for (const b of document.querySelectorAll('.mode')) {
    const on = b.dataset.mode === next;
    b.setAttribute('aria-checked', on ? 'true' : 'false');
    b.classList.toggle('on', on);
  }
  document.querySelector('#signin-user').textContent = next;
  document.querySelector('#password').value = '';
  signinError.classList.add('hidden');
  document.querySelector('#password').focus();
}
function showSignin(message) {
  session = null;
  inventory = null;
  list.replaceChildren();
  app.classList.add('hidden');
  signout.classList.add('hidden');
  signin.classList.remove('hidden');
  if (message) { signinError.textContent = message; signinError.classList.remove('hidden'); }
  setMode(mode);
}
function showApp() {
  signin.classList.add('hidden');
  app.classList.remove('hidden');
  signout.classList.remove('hidden');
  document.querySelector('#app-sub').textContent = session.mode === 'push'
    ? 'Publisher access: you can delete tags and repositories.'
    : 'Read-only access: browse and pull images.';
}
for (const b of document.querySelectorAll('.mode')) b.addEventListener('click', () => setMode(b.dataset.mode));
signinForm.addEventListener('submit', async event => {
  event.preventDefault();
  const pw = document.querySelector('#password').value;
  if (!pw) return;
  const user = mode;
  // Passwords ride only in the Authorization header of this request's session.
  const candidate = { mode, user, auth: 'Basic ' + btoa(user + ':' + pw) };
  signinSubmit.disabled = true;
  signinError.classList.add('hidden');
  try {
    const response = await fetch('/api/inventory', {cache:'no-store', credentials:'omit', headers:{Authorization: candidate.auth}});
    if (response.status === 401) {
      signinError.textContent = 'That password was not accepted.';
      signinError.classList.remove('hidden');
      document.querySelector('#password').select();
      return;
    }
    if (!response.ok) throw Error('HTTP ' + response.status);
    session = candidate;
    document.querySelector('#password').value = '';
    showApp();
    inventory = await response.json();
    applyInventory();
  } catch (error) {
    signinError.textContent = 'Sign-in failed: ' + error.message;
    signinError.classList.remove('hidden');
  } finally {
    signinSubmit.disabled = false;
  }
});
signout.addEventListener('click', () => showSignin());
filter.addEventListener('input',render);
refresh.addEventListener('click',load);
getHealth();
showSignin();
