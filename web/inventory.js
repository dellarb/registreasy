'use strict';
const list = document.querySelector('#repositories');
const notice = document.querySelector('#notice');
const filter = document.querySelector('#filter');
const refresh = document.querySelector('#refresh');
let inventory = null;
// The server holds the session; the browser only has an HttpOnly cookie this
// script cannot read. The password is sent once, to sign in, and never stored.
let session = null; // { username, role } from /api/session
const signin = document.querySelector('#signin');
const app = document.querySelector('#app');
const signout = document.querySelector('#signout');
const signinForm = document.querySelector('#signin-form');
const signinError = document.querySelector('#signin-error');
const signinSubmit = document.querySelector('#signin-submit');

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
// Every API call sends the session cookie (same origin only). State-changing
// calls add X-Registreasy-Action, which a cross-site page cannot send.
function api(path, method, action, body) {
  const headers = {};
  if (action) headers['X-Registreasy-Action'] = action;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  return fetch(path, {
    method: method || 'GET', cache: 'no-store', credentials: 'same-origin', headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
const EXPIRED = 'Your session has expired. Please sign in again.';
async function callDelete(body) {
  const response = await api('/api/delete', 'POST', 'delete', body);
  const payload = await response.json().catch(() => ({}));
  if (response.status === 401) { showSignin(EXPIRED); throw Error('signed out'); }
  if (response.status === 429) throw Error('Too many requests; wait a few seconds and try again.');
  if (!response.ok) throw Error(payload.message || payload.error || ('HTTP ' + response.status));
  return payload;
}
function showNotice(message, isError) {
  notice.textContent = message;
  notice.classList.toggle('error', !!isError);
  notice.classList.remove('hidden');
}
function describe(plan) {
  if (plan.empty) return 'Remove the empty repository ' + plan.repository + '?\n\nIt has no tags; its leftover directory will be removed.';
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
    // plan_id makes the server refuse if the registry changed since the preview.
    const done = await callDelete({ ...body, plan_id: plan.plan_id });
    await load();
    if (session && inventory) showNotice('Deleted ' + (done.scope === 'repository' ? done.repository : done.repository + ':' + done.tag) + '.', false);
  } catch (error) {
    if (session) showNotice('Delete failed: ' + error.message, true);
  }
}
function button(label, className, onClick) {
  const b = el('button', className, label);
  b.type = 'button';
  b.addEventListener('click', onClick);
  return b;
}
function imageGroups(tags) {
  const groups = [];
  const byDigest = new Map();
  for (const tag of tags) {
    let group = tag.digest && byDigest.get(tag.digest);
    if (!group) {
      group = [];
      groups.push(group);
      if (tag.digest) byDigest.set(tag.digest, group);
    }
    group.push(tag);
  }
  return groups;
}
function sizeLabel(bytes) {
  if (!Number.isSafeInteger(bytes) || bytes < 0) return 'Unavailable';
  if (bytes < 1024) return bytes + ' B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  let unit = -1;
  do { bytes /= 1024; unit++; } while (bytes >= 1024 && unit < units.length - 1);
  return bytes.toFixed(1) + ' ' + units[unit];
}
function render() {
  list.replaceChildren();
  if (!inventory) return;
  const search = filter.value.trim().toLowerCase();
  const canDelete = inventory.can_delete === true;
  let shown = 0;
  for (const repo of inventory.repositories) {
    const match = repo.name.toLowerCase().includes(search);
    const groups = imageGroups(repo.tags).filter(group => match || group.some(tag => tag.tag.toLowerCase().includes(search)));
    if (!match && !groups.length) continue;
    const tags = groups.flat();
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
      for (const title of ['Tag / version','Tag updated¹','Image built²','Size³','Digest']) titles.append(el('th','',title));
      if (canDelete) titles.append(el('th','actions',''));
      thead.append(titles); table.append(thead);
      const tbody = el('tbody');
      for (const group of groups) {
        const tag = group[0];
        const row = el('tr');
        const label = el('td');
        const latest = group.find(item => item.tag === 'latest');
        const revision = group.find(item => /^rev-[a-f0-9]{7,}/i.test(item.tag));
        const displayed = latest && revision
          ? [latest, revision, ...group.filter(item => item !== latest && item !== revision)]
          : group;
        for (const item of displayed) {
          const tagLabel = el('span', /^rev-[a-f0-9]{7,}/i.test(item.tag) ? 'tag-sha' : 'tag', item.tag);
          tagLabel.title = item.tag;
          label.append(tagLabel);
        }
        row.append(label);
        row.append(el('td',tag.tag_updated_at?'':'missing',formatted(tag.tag_updated_at)));
        row.append(el('td',tag.built_at?'':'missing',formatted(tag.built_at)));
        const size = el('td', tag.size_bytes == null ? 'missing' : '', sizeLabel(tag.size_bytes));
        if (tag.platform) size.append(el('small', 'platform', tag.platform));
        row.append(size);
        const digestCell = el('td');
        const digest = el('code','',tag.digest ? tag.digest.slice(0,23) + '…' : 'Unavailable');
        if (tag.digest) digest.title = tag.digest;
        digestCell.append(digest); row.append(digestCell);
        if (canDelete) {
          const cell = el('td','actions');
          cell.append(button('Delete', 'danger small', () => deleteFlow(repo.name, tag.tag)));
          row.append(cell);
        }
        tbody.append(row);
      }
      table.append(tbody);wrapper.append(table);card.append(wrapper);
    } else card.append(el('div','no-tags', repo.error ? 'Tags could not be read' : 'No tags found'));
    const foot=el('div','repo-foot');
    foot.append(el('span','', 'Last tagged: '+formatted(repo.updated_at)),el('span','', canDelete ? 'Publisher access' : 'Read-only'));
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
  document.querySelector('#registry-size').textContent=sizeLabel(inventory.size_bytes);
  document.querySelector('#last-checked').textContent=formatted(inventory.generated_at);
  render();
}
async function load() {
  if (!session) return showSignin();
  refresh.disabled=true;
  notice.textContent='Loading inventory…';
  notice.classList.remove('hidden','error');
  try {
    const response = await api('/api/inventory');
    if (response.status === 401) { showSignin(EXPIRED); return; }
    if (response.status === 429) throw Error('Too many requests; wait a few seconds and refresh.');
    if (!response.ok) throw Error('Inventory unavailable (HTTP '+response.status+')');
    inventory=await response.json();
    applyInventory();
  } catch(error) {
    inventory=null;list.replaceChildren();notice.textContent=error.message || 'Inventory unavailable';notice.classList.add('error');
  } finally { refresh.disabled=false; }
  await getHealth();
}
function resetSigninForm() {
  document.querySelector('#password').value = '';
  signinError.classList.add('hidden');
  const username = document.querySelector('#username');
  (username.value ? document.querySelector('#password') : username).focus();
}
function showSignin(message) {
  session = null;
  inventory = null;
  list.replaceChildren();
  app.classList.add('hidden');
  signout.classList.add('hidden');
  signin.classList.remove('hidden');
  resetSigninForm();
  if (message) { signinError.textContent = message; signinError.classList.remove('hidden'); }
}
function showApp() {
  signin.classList.add('hidden');
  app.classList.remove('hidden');
  signout.classList.remove('hidden');
  document.querySelector('#app-sub').textContent = session && session.can_delete
    ? 'Publisher access: you can delete tags and repositories.'
    : 'Read-only access: browse and pull images.';
}
signinForm.addEventListener('submit', async event => {
  event.preventDefault();
  const pw = document.querySelector('#password').value;
  const user = document.querySelector('#username').value.trim();
  if (!pw || !user) return;
  signinSubmit.disabled = true;
  signinError.classList.add('hidden');
  try {
    const response = await api('/api/session', 'POST', 'signin', { username: user, password: pw });
    document.querySelector('#password').value = '';
    if (response.status === 401) {
      signinError.textContent = 'That username or password was not accepted.';
      signinError.classList.remove('hidden');
      document.querySelector('#password').focus();
      return;
    }
    if (response.status === 429) throw Error('too many attempts; wait a while and try again');
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw Error(payload.message || ('HTTP ' + response.status));
    session = payload;
    showApp();
    await load();
  } catch (error) {
    signinError.textContent = 'Sign-in failed: ' + error.message;
    signinError.classList.remove('hidden');
  } finally {
    signinSubmit.disabled = false;
  }
});
signout.addEventListener('click', async () => {
  try { await api('/api/session', 'DELETE', 'signout'); } catch { /* signed out locally regardless */ }
  showSignin();
});
filter.addEventListener('input',render);
refresh.addEventListener('click',load);
// Resume an existing session (e.g. after a reload) without asking again.
async function start() {
  getHealth();
  try {
    const response = await api('/api/session');
    if (response.ok) { session = await response.json(); showApp(); await load(); return; }
  } catch { /* fall through to the sign-in form */ }
  showSignin();
}
start();
