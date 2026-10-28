const buttons = ['fill', 'save', 'generate'].map(id => document.getElementById(id));
let running = false;
async function refresh() {
  try {
    const state = await chrome.runtime.sendMessage({ action: 'status' });
    document.getElementById('origin').textContent = state.origin || 'No supported website';
    document.getElementById('status').textContent = state.message;
    document.querySelector('.status').dataset.kind = state.kind;
    document.getElementById('cancel').hidden = !state.busy;
    for (const button of buttons) button.disabled = state.busy || !state.supported || running;
  } catch {
    document.getElementById('status').textContent = 'Reload the extension in chrome://extensions, then try again.';
    for (const button of buttons) button.disabled = true;
  }
}
for (const button of [...buttons, document.getElementById('cancel')]) {
  button.addEventListener('click', async () => {
    running = true;
    for (const item of buttons) item.disabled = true;
    try { await chrome.runtime.sendMessage({ action: button.id }); }
    finally { running = false; await refresh(); }
  });
}
void refresh();
setInterval(refresh, 750);
