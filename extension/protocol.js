export const HOST = 'org.proximus.browser';
export const VERSION = 1;
export const REQUEST_TIMEOUT = 120_000;
export const EXTENSION_ID = 'ggbcckdjjdkabfcionkinepdlcddgcfm';

export function websiteOrigin(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || !url.hostname || url.hostname.endsWith('.')) {
    throw new Error('Open an HTTPS sign-in page to use Proximus.');
  }
  return url.origin;
}

export function validateLogin(login, titleRequired = false) {
  const size = value => typeof value === 'string' ? new TextEncoder().encode(value).length : Infinity;
  if (!login || size(login.username) > 2048 || size(login.password) > 4096 || !login.password ||
      (titleRequired && (!login.title || size(login.title) > 256))) {
    throw new Error('This login is empty or exceeds the supported size.');
  }
  return login;
}

export function validateReply(reply, request) {
  if (!reply || reply.version !== VERSION || reply.id !== request.id || reply.origin !== request.origin) {
    throw new Error('The response did not match this request. Nothing was filled.');
  }
  if (reply.status === 'cancelled') throw new Error('The request was cancelled.');
  if (reply.status === 'error') throw new Error('Proximus could not complete the request. Try again in the app.');
  if (request.action === 'fill' && reply.status === 'filled') return validateLogin(reply.login);
  if (request.action === 'save' && reply.status === 'saved' && !reply.login) return null;
  throw new Error('Proximus returned an unsupported response.');
}

export function generatePassword(length = 24) {
  if (!Number.isInteger(length) || length < 16 || length > 64) throw new Error('Choose 16 to 64 characters.');
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%&*-_=+?';
  const ceiling = 256 - (256 % alphabet.length);
  let password = '';
  while (password.length < length) {
    const bytes = crypto.getRandomValues(new Uint8Array(128));
    for (const byte of bytes) {
      if (byte < ceiling) password += alphabet[byte % alphabet.length];
      if (password.length === length) break;
    }
    bytes.fill(0);
  }
  return password;
}
