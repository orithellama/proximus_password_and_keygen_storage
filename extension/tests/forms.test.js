import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { interactWithForm } from '../forms.js';

function fixture({ passwordCount = 1, formAction = 'https://example.com/login', newPassword = false } = {}) {
  class Input {
    constructor(type, name) { Object.assign(this, { type, name, id: name, autocomplete: '', form, disabled: false, readOnly: false, isConnected: true, hidden: false, raw: '' }); }
    get value() { return this.raw; } set value(value) { this.raw = value; }
    getClientRects() { return this.hidden ? [] : [1]; }
    checkVisibility() { return !this.hidden; }
    closest() { return null; }
    hasAttribute() { return false; }
    dispatchEvent(event) { events.push(event.type); }
  }
  const form = { action: formAction, elements: [] }, events = [];
  const username = new Input('email', 'email');
  const passwords = Array.from({ length: passwordCount }, (_, i) => new Input('password', 'password' + i));
  if (newPassword) for (const input of passwords) input.autocomplete = 'new-password';
  form.elements = [username, ...passwords];
  const document = { visibilityState: 'visible', baseURI: 'https://example.com/login', activeElement: null, querySelectorAll() { return form.elements; } };
  const window = {}; window.top = window;
  const timers = [];
  const context = vm.createContext({ window, document, location: { protocol: 'https:', origin: 'https://example.com', hostname: 'example.com' }, isSecureContext: true, HTMLInputElement: Input, Event, URL, TextEncoder, setTimeout: fn => { timers.push(fn); return timers.length; }, clearTimeout() {} });
  const run = vm.runInContext('(' + interactWithForm.toString() + ')', context);
  const invoke = (action, token = 'request', login = { username: 'fixture@example.com', password: 'fixture secret' }) => {
    const result = run(action, 'https://example.com', token, login);
    if (result.error) throw new Error(result.error);
    return result;
  };
  return { invoke, context, form, username, passwords, document, timers, events };
}

test('fills visible fields once without submitting', () => {
  const f = fixture();
  f.invoke('prepare'); f.invoke('fill');
  assert.equal(f.username.value, 'fixture@example.com');
  assert.equal(f.passwords[0].value, 'fixture secret');
  assert.deepEqual(f.events, ['input', 'change', 'input', 'change']);
  assert.throws(() => f.invoke('fill'));
});
test('hidden, replaced, cross-origin, and wrong-type fields cannot receive passwords', () => {
  for (const mutate of [f => { f.passwords[0].hidden = true; }, f => { f.passwords[0].isConnected = false; }, f => { f.form.action = 'https://evil.example'; }, f => { f.passwords[0].type = 'text'; }, f => { f.document.visibilityState = 'hidden'; }, f => { f.context.location.origin = 'https://other.example'; }]) {
    const f = fixture(); f.invoke('prepare'); mutate(f);
    assert.throws(() => f.invoke('fill'));
    assert.equal(f.passwords[0].value, '');
  }
});
test('rejects non-HTTPS, subframes, cross-origin forms and ambiguous passwords', () => {
  const http = fixture(); http.context.location.protocol = 'http:'; assert.throws(() => http.invoke('prepare'));
  const frame = fixture(); frame.context.window.top = {}; assert.throws(() => frame.invoke('prepare'));
  assert.throws(() => fixture({ formAction: 'https://evil.example' }).invoke('prepare'));
  assert.throws(() => fixture({ passwordCount: 2 }).invoke('prepare'));
});
test('rechecks password destination after a page reacts to the username input event', () => {
  const f = fixture(); f.invoke('prepare');
  f.username.dispatchEvent = () => { f.passwords[0].type = 'text'; };
  assert.throws(() => f.invoke('fill'));
  assert.equal(f.passwords[0].value, '');
});
test('replays, a changed token, and timed-out plans never fill', () => {
  const f = fixture(); f.invoke('prepare'); assert.throws(() => f.invoke('fill', 'different'));
  f.invoke('prepare'); f.timers.at(-1)(); assert.throws(() => f.invoke('fill'));
});
test('username-only login steps are supported without exposing the password', () => {
  const f = fixture({ passwordCount: 0 });
  f.invoke('prepare'); const result = f.invoke('fill');
  assert.equal(result.usernameOnly, true); assert.equal(f.username.value, 'fixture@example.com');
});
test('generator fills matching new-password fields but never current-password fields', () => {
  const f = fixture({ passwordCount: 2, newPassword: true });
  f.invoke('prepare-generated'); f.invoke('generated');
  assert.ok(f.passwords.every(input => input.value === 'fixture secret'));
  assert.equal(f.username.value, '');
  const current = fixture(); current.passwords[0].autocomplete = 'current-password';
  assert.throws(() => current.invoke('prepare-generated'));
});
test('saving requires explicit matching nonempty passwords', () => {
  const f = fixture({ passwordCount: 2, newPassword: true });
  assert.throws(() => f.invoke('capture'));
  f.passwords[0].value = 'fixture'; assert.throws(() => f.invoke('capture'));
  f.passwords[1].value = 'fixture'; f.username.value = 'test@example.com';
  const result = f.invoke('capture');
  assert.equal(result.login.password, 'fixture'); assert.equal(result.login.username, 'test@example.com');
});
test('password-change forms save the matching new password, not the current one', () => {
  const f = fixture({ passwordCount: 3 });
  f.passwords[0].autocomplete = 'current-password'; f.passwords[0].value = 'previous password';
  for (const input of f.passwords.slice(1)) { input.autocomplete = 'new-password'; input.value = 'replacement password'; }
  assert.equal(f.invoke('capture').login.password, 'replacement password');
  f.passwords[2].value = 'different confirmation';
  assert.throws(() => f.invoke('capture'));
});
