import test from 'node:test';
import assert from 'node:assert/strict';

function event() {
  const listeners = [];
  return { addListener(fn) { listeners.push(fn); }, async emit(...args) { return Promise.all(listeners.map(fn => fn(...args))); }, listeners };
}
async function fixture() {
  const tab = { id: 7, active: true, windowId: 1, url: 'https://example.com/login', incognito: false };
  const calls = [], ports = [];
  let documentId = 'document-one';
  const api = {
    runtime: { id: 'fixture', getURL: path => 'chrome-extension://fixture/' + path, onMessage: event(),
      connectNative() {
        const port = { onMessage: event(), onDisconnect: event(), disconnect() { port.disconnected = true; }, postMessage(message) { port.request = structuredClone(message); } };
        ports.push(port); return port;
      } },
    tabs: { query: async () => [tab], get: async () => tab, onRemoved: event(), onActivated: event(), onUpdated: event() },
    scripting: { executeScript: async options => {
      calls.push(options);
      return [{ frameId: 0, documentId, result: options.args[0] === 'capture' ? { login: { title: 'Example', username: 'test', password: 'fixture password' } } : { ok: true } }];
    } },
  };
  globalThis.chrome = api;
  await import('../background.js?' + crypto.randomUUID());
  const sender = { id: api.runtime.id, url: api.runtime.getURL('popup.html') };
  const send = (action, source = sender) => new Promise(resolve => {
    const returned = api.runtime.onMessage.listeners[0]({ action }, source, resolve);
    if (returned === false) resolve(undefined);
  });
  const waitFor = async condition => {
    for (let i = 0; i < 100; i++) { if (condition()) return; await new Promise(resolve => setImmediate(resolve)); }
    throw new Error('The worker did not settle');
  };
  const begin = async action => { await send(action); await waitFor(() => ports[0]?.request); return ports[0]; };
  const reply = port => ({ ...port.request, status: 'filled', login: { username: 'test', password: 'fixture password' } });
  return { api, tab, calls, ports, send, begin, reply, waitFor, document: id => { documentId = id; } };
}

test('page and forged sender messages cannot request credentials', async () => {
  const f = await fixture();
  await f.send('fill', { id: 'fixture', url: 'https://example.com', tab: f.tab });
  await f.send('fill', { id: 'another-extension', url: 'chrome-extension://fixture/popup.html' });
  await f.send('fill', { id: 'fixture', url: 'chrome-extension://fixture/popup.html?spoof=1' });
  assert.equal(f.calls.length, 0); assert.equal(f.ports.length, 0);
});
test('fill is bound to the prepared top-level document and never returned to popup', async () => {
  const f = await fixture(), port = await f.begin('fill');
  await port.onMessage.emit(f.reply(port));
  const fill = f.calls.find(call => call.args[0] === 'fill');
  assert.deepEqual(fill.target, { tabId: 7, documentIds: ['document-one'] });
  assert.equal(fill.world, 'ISOLATED');
  assert.equal(fill.args[1], 'https://example.com');
  assert.equal(port.disconnected, true);
  const status = await f.send('status');
  assert.equal(status.kind, 'success');
  assert.equal(JSON.stringify(status).includes('fixture password'), false);
  await port.onMessage.emit(f.reply(port));
  assert.equal(f.calls.filter(call => call.args[0] === 'fill').length, 1);
});
test('mismatched origin or request never reaches form filling', async () => {
  for (const changed of [{ origin: 'https://evil.example' }, { id: 'another-request' }]) {
    const f = await fixture(), port = await f.begin('fill');
    await port.onMessage.emit({ ...f.reply(port), ...changed });
    assert.equal(f.calls.some(call => call.args[0] === 'fill'), false);
    assert.equal((await f.send('status')).kind, 'error');
  }
});
test('cancel, tab close, tab switch, and navigation reject late replies', async () => {
  for (const cancel of [f => f.send('cancel'), f => f.api.tabs.onRemoved.emit(7), f => f.api.tabs.onActivated.emit({ tabId: 8 }), f => f.api.tabs.onUpdated.emit(7, { status: 'loading' })]) {
    const f = await fixture(), port = await f.begin('fill');
    await cancel(f);
    await port.onMessage.emit(f.reply(port));
    assert.equal(port.disconnected, true);
    assert.equal(f.calls.some(call => call.args[0] === 'fill'), false);
  }
});
test('origin change during approval is checked even if navigation events were missed', async () => {
  const f = await fixture(), port = await f.begin('fill');
  f.tab.url = 'https://other.example';
  await port.onMessage.emit(f.reply(port));
  assert.equal(f.calls.some(call => call.args[0] === 'fill'), false);
});
test('save carries only explicit capture and does not write it back to the page', async () => {
  const f = await fixture(), port = await f.begin('save');
  assert.deepEqual(port.request.login, { title: 'Example', username: 'test', password: 'fixture password' });
  const { login, ...request } = port.request;
  await port.onMessage.emit({ ...request, status: 'saved' });
  assert.equal(f.calls.length, 1);
  assert.equal((await f.send('status')).kind, 'success');
});
test('generation stays in browser memory and does not call the native host', async () => {
  const f = await fixture();
  await f.send('generate');
  await f.waitFor(() => f.calls.length === 2);
  const fill = f.calls[1];
  assert.equal(fill.args[0], 'generated');
  assert.equal(fill.args[3].password.length, 24);
  assert.deepEqual(fill.target.documentIds, ['document-one']);
  assert.equal(f.ports.length, 0);
});
test('two rapid requests cannot open two native hosts', async () => {
  const f = await fixture();
  await Promise.all([f.send('fill'), f.send('fill')]);
  await f.waitFor(() => f.ports[0]?.request);
  assert.equal(f.ports.length, 1);
  await f.send('cancel');
});
