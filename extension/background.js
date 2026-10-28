import { HOST, VERSION, REQUEST_TIMEOUT, websiteOrigin, validateLogin, validateReply, generatePassword } from './protocol.js';
import { interactWithForm } from './forms.js';

let pending = null;
let state = { busy: false, message: 'Ready when you are.', kind: 'ready' };
function report(message, kind = 'ready') { state = { busy: !!pending, message, kind }; }
function messageOf(error) { return error instanceof Error ? error.message : 'The request could not be completed.'; }
const trustedPopup = sender => sender.id === chrome.runtime.id && sender.url === chrome.runtime.getURL('popup.html') && !sender.tab;

async function currentTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!Number.isInteger(tab?.id) || tab.incognito) throw new Error('Open a normal browser window to use Proximus.');
  return { tab, origin: websiteOrigin(tab.url) };
}
async function checkTab(context) {
  const tab = await chrome.tabs.get(context.tab.id);
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab.active || active?.id !== tab.id || tab.windowId !== context.tab.windowId || websiteOrigin(tab.url) !== context.origin) {
    throw new Error('The active website changed. Nothing was filled.');
  }
}
async function inject(context, operation, login = null) {
  if (pending?.id !== context.id) throw new Error('The request was cancelled.');
  await checkTab(context);
  if (pending?.id !== context.id) throw new Error('The request was cancelled.');
  const target = context.documentId ? { tabId: context.tab.id, documentIds: [context.documentId] } : { tabId: context.tab.id, frameIds: [0] };
  const results = await chrome.scripting.executeScript({ target, world: 'ISOLATED', func: interactWithForm,
    args: [operation, context.origin, context.id, login] });
  const result = results[0];
  if (results.length !== 1 || result.frameId !== 0 || !result.documentId || (context.documentId && result.documentId !== context.documentId) || !result.result) {
    throw new Error('The page changed or could not be filled. Open Proximus again.');
  }
  if (typeof result.result.error === 'string') throw new Error(result.result.error);
  context.documentId = result.documentId;
  return result.result;
}
function disconnect(operation) {
  clearTimeout(operation.timer);
  operation.port?.disconnect();
  if (pending === operation) pending = null;
}
async function start(action) {
  if (pending) throw new Error('Finish or cancel the current request first.');
  // Reserve before the first await so two popup messages cannot start two hosts.
  const operation = { id: crypto.randomUUID(), action, port: null, context: null, done: false };
  pending = operation;
  report('Checking this website…', 'waiting');
  let request;
  try {
    const context = { ...await currentTab(), id: operation.id };
    operation.context = context;
    const fields = await inject(context, action === 'save' ? 'capture' : action === 'generate' ? 'prepare-generated' : 'prepare');
    if (pending !== operation) throw new Error('Cancelled.');
    if (action === 'generate') {
      let password = generatePassword();
      try { await inject(context, 'generated', { username: '', password }); }
      finally { password = ''; }
      disconnect(operation);
      report('New password filled. Choose Save this login before leaving the page.', 'success');
      return;
    }
    request = { version: VERSION, id: operation.id, action, origin: context.origin };
    if (action === 'save') request.login = validateLogin(fields.login, true);
    const port = chrome.runtime.connectNative(HOST);
    operation.port = port;
    operation.timer = setTimeout(() => {
      if (pending !== operation) return;
      disconnect(operation);
      report('The approval expired. Try again.', 'error');
    }, REQUEST_TIMEOUT);
    port.onMessage.addListener(async reply => {
      if (pending !== operation || operation.done) return;
      operation.done = true;
      let login;
      try {
        login = validateReply(reply, request);
        if (action === 'fill') {
          const filled = await inject(context, 'fill', login);
          report(filled.usernameOnly ? 'Username filled. Continue on the website, then use Proximus for the password step.' : 'Login filled. You can now sign in on the website.', 'success');
        } else { report('Login saved in Proximus.', 'success'); }
      } catch (error) { report(messageOf(error), 'error'); }
      finally {
        if (reply?.login) { reply.login.password = ''; reply.login.username = ''; }
        login = null;
        disconnect(operation);
        state.busy = false;
      }
    });
    port.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError;
      if (pending !== operation || operation.done) return;
      disconnect(operation);
      report(error ? 'Could not connect. Install the current Mac app and run ./install --browser from its source folder.' : 'The Proximus window closed. Nothing was filled.', 'error');
    });
    port.postMessage(request);
    if (request.login) { request.login.password = ''; request.login.username = ''; delete request.login; }
    report('Approve this request in the Proximus window. You can close this popup.', 'waiting');
  } catch (error) {
    disconnect(operation);
    report(messageOf(error), 'error');
  } finally {
    if (request?.login) { request.login.password = ''; request.login.username = ''; }
  }
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (!trustedPopup(sender) || !message || typeof message !== 'object') return false;
  if (message.action === 'status') {
    currentTab().then(({ origin }) => respond({ ...state, origin, supported: true })).catch(error => respond({ ...state, origin: '', supported: false, message: state.busy ? state.message : messageOf(error) }));
    return true;
  }
  if (message.action === 'cancel') {
    if (pending && !pending.done) { disconnect(pending); report('Cancelled. Nothing was filled.', 'ready'); }
    respond({ ok: true }); return false;
  }
  if (['fill', 'save', 'generate'].includes(message.action)) {
    if (pending) { respond({ ok: false }); return false; }
    void start(message.action);
    respond({ ok: true }); return false;
  }
  return false;
});
chrome.tabs.onRemoved.addListener(id => {
  if (pending?.context?.tab.id === id && !pending.done) { disconnect(pending); report('The tab closed. Request cancelled.', 'ready'); }
});
chrome.tabs.onActivated.addListener(({ tabId }) => {
  if (pending?.context && pending.context.tab.id !== tabId && !pending.done) {
    disconnect(pending); report('The active tab changed. Request cancelled.', 'ready');
  }
});
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (pending?.context?.tab.id === tabId && change.status === 'loading' && !pending.done) {
    disconnect(pending); report('The page changed. Request cancelled.', 'ready');
  }
});
