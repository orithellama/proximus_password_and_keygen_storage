// Runs only in Chrome's isolated world after a toolbar action. No page message listener.
// Keep this function self-contained: Chrome serializes it for executeScript.
export function interactWithForm(operation, origin, token, login = null) {
  try {
    const fail = message => { throw new Error(message); };
    if (window.top !== window || location.protocol !== 'https:' || location.origin !== origin || !isSecureContext || document.visibilityState !== 'visible') {
      fail('The website changed or is no longer visible. Open Proximus again.');
    }
    const key = Symbol.for('proximus.browser.form.v1');
    const visible = input => input instanceof HTMLInputElement && input.isConnected && !input.disabled && !input.readOnly &&
      !input.closest('[inert], [aria-hidden="true"]') && input.getClientRects().length > 0 &&
      input.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    const safeForm = input => {
      if (!visible(input)) return false;
      const form = input.form;
      if (!form) return true;
      const sameOrigin = value => { try { return new URL(value, document.baseURI).origin === origin; } catch { return false; } };
      if (!sameOrigin(form.action)) return false;
      return [...form.elements].every(element => !element.hasAttribute('formaction') || sameOrigin(element.formAction));
    };
    const clear = () => { const plan = globalThis[key]; if (plan) clearTimeout(plan.timer); delete globalThis[key]; };
    if (operation === 'clear') { clear(); return { ok: true }; }

    if (operation === 'fill' || operation === 'generated') {
      const plan = globalThis[key];
      clear();
      if (!plan || plan.token !== token || plan.origin !== origin || Date.now() - plan.created > 120_000 ||
          plan.mode !== (operation === 'fill' ? 'prepare' : 'prepare-generated')) fail('This request expired. Open Proximus again.');
      if (!login || typeof login.username !== 'string' || typeof login.password !== 'string') fail('No login was supplied.');
      const targets = [...plan.passwords, ...(operation === 'fill' && plan.username ? [plan.username] : [])];
      if (!targets.length || targets.some(input => !safeForm(input) || input.form !== plan.form)) fail('The form changed. Open Proximus again.');
      if (plan.passwords.some(input => input.type !== 'password' || (operation === 'fill' && input.autocomplete === 'new-password') ||
          (operation === 'generated' && input.autocomplete === 'current-password'))) fail('The password field changed.');
      if (operation === 'fill' && plan.username && !['text', 'email', 'tel'].includes(plan.username.type)) fail('The username field changed.');
      const setValue = (input, value, passwordField) => {
        if (!safeForm(input) || input.form !== plan.form || location.origin !== origin || document.visibilityState !== 'visible' ||
            (passwordField && (input.type !== 'password' || (operation === 'fill' && input.autocomplete === 'new-password') ||
              (operation === 'generated' && input.autocomplete === 'current-password'))) ||
            (!passwordField && !['text', 'email', 'tel'].includes(input.type))) fail('The form changed while filling.');
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(input, value);
        input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      };
      if (operation === 'fill' && plan.username) setValue(plan.username, login.username, false);
      for (const input of plan.passwords) setValue(input, login.password, true);
      return { ok: true, usernameOnly: plan.passwords.length === 0 };
    }

    clear();
    if (!['prepare', 'prepare-generated', 'capture'].includes(operation)) fail('Unsupported action.');
    const inputs = [...document.querySelectorAll('input')].filter(visible);
    const generated = operation === 'prepare-generated';
    const passwords = inputs.filter(input => input.type === 'password' &&
      (generated ? input.autocomplete !== 'current-password' : operation === 'capture' || input.autocomplete !== 'new-password'));
    const usernames = inputs.filter(input => ['email', 'text', 'tel'].includes(input.type) &&
      (['username', 'email'].includes(input.autocomplete) || input.type === 'email' || /user|email|login|identifier/i.test(input.name + ' ' + input.id)) &&
      !/one-time-code|cc-/i.test(input.autocomplete));
    const candidates = passwords.length ? passwords : (generated ? [] : usernames);
    if (!candidates.length) fail(generated ? 'Click a new-password field first. Proximus does not replace current-password fields.' : 'No sign-in fields found. Open the sign-in form first.');
    const active = document.activeElement;
    let anchor = candidates.includes(active) ? active : null;
    if (!anchor && active instanceof HTMLInputElement) {
      const matching = candidates.filter(input => input.form && input.form === active.form);
      if (matching.length) anchor = matching[0];
    }
    const forms = new Set(candidates.map(input => input.form));
    if (!anchor && forms.size !== 1) fail('Click a field in the sign-in form you want to use, then open Proximus.');
    anchor ??= candidates[0];
    const form = anchor.form;
    let group = passwords.filter(input => input.form === form);
    if (operation === 'capture' && group.some(input => input.autocomplete === 'new-password')) {
      group = group.filter(input => input.autocomplete === 'new-password');
    }
    if (group.length > (generated || operation === 'capture' ? 2 : 1)) fail('More than one password field was found. Use the Proximus app for this form.');
    const userGroup = usernames.filter(input => input.form === form);
    if (userGroup.length > 1 && !userGroup.includes(active)) fail('Click the email or username field, then open Proximus.');
    const username = userGroup.includes(active) ? active : userGroup[0];
    if ([...group, ...(username ? [username] : [])].some(input => !safeForm(input))) fail('This form sends information to another website. Proximus will not fill it.');
    if (operation === 'capture') {
      if (!group.length || !group[0].value || group.some(input => input.value !== group[0].value)) fail('Enter a password first. Confirmation fields must match.');
      const bytes = value => new TextEncoder().encode(value).length;
      if (bytes(group[0].value) > 4096 || bytes(username?.value ?? '') > 2048) fail('This login exceeds the supported size.');
      return { login: { title: location.hostname, username: username?.value ?? '', password: group[0].value } };
    }
    globalThis[key] = { token, origin, mode: operation, created: Date.now(), form, username, passwords: group,
      timer: setTimeout(clear, 120_000) };
    return { ok: true, usernameOnly: group.length === 0 };
  } catch (error) {
    return { error: error instanceof Error ? error.message.slice(0, 240) : 'This form could not be used. Open Proximus again.' };
  }
}
