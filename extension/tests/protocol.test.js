import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { VERSION, EXTENSION_ID, websiteOrigin, validateReply, generatePassword } from '../protocol.js';

test('origin preserves subdomains and non-default ports and rejects unsafe schemes', () => {
  assert.equal(websiteOrigin('https://login.example.com/a?q=x'), 'https://login.example.com');
  assert.equal(websiteOrigin('https://example.com:8443/a'), 'https://example.com:8443');
  for (const url of ['http://example.com', 'https://u:p@example.com', 'https://example.com./', 'file:///tmp/test', 'chrome://settings', 'javascript:alert(1)']) assert.throws(() => websiteOrigin(url));
});
test('replies are bound to request, origin, version, action and bounded credentials', () => {
  const request = { version: VERSION, id: 'one-request', action: 'fill', origin: 'https://example.com' };
  const reply = { ...request, status: 'filled', login: { username: 'test', password: 'fixture' } };
  assert.deepEqual(validateReply(reply, request), reply.login);
  for (const changed of [{ id: 'another-request' }, { origin: 'https://evil.example' }, { version: 2 }, { status: 'saved' }, { status: 'cancelled' }, { login: { username: 'x', password: 'x'.repeat(4097) } }]) {
    assert.throws(() => validateReply({ ...reply, ...changed }, request));
  }
  assert.throws(() => validateReply(reply, { ...request, action: 'save' }));
  assert.equal(validateReply({ ...request, status: 'saved' }, { ...request, action: 'save' }), null);
});
test('generation uses bounded lengths and produces distinct 24 character passwords', () => {
  const generated = new Set(Array.from({ length: 200 }, () => generatePassword()));
  assert.equal(generated.size, 200);
  for (const password of generated) assert.match(password, /^[A-Za-z2-9!@#$%&*_=+?-]{24}$/);
  for (const size of [0, 15, 65, NaN, 24.5]) assert.throws(() => generatePassword(size));
});
test('manifest pins identity and grants no persistent website, storage, or network access', async () => {
  const manifest = JSON.parse(await readFile(new URL('../manifest.json', import.meta.url), 'utf8'));
  const id = [...createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32)].map(c => String.fromCharCode(97 + parseInt(c, 16))).join('');
  assert.equal(id, EXTENSION_ID);
  const native = await readFile(new URL('../../Sources/ProximusKit/BrowserProtocol.swift', import.meta.url), 'utf8');
  assert.ok(native.includes('static let extensionID = "' + id + '"'));
  assert.deepEqual(manifest.permissions.sort(), ['activeTab', 'nativeMessaging', 'scripting'].sort());
  for (const key of ['host_permissions', 'content_scripts', 'externally_connectable', 'web_accessible_resources']) assert.equal(manifest[key], undefined);
  assert.match(manifest.content_security_policy.extension_pages, /connect-src 'none'/);
  assert.equal(manifest.incognito, 'not_allowed');
});
