import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash, webcrypto } from 'node:crypto';
import vm from 'node:vm';
import ts from 'typescript';

const root = new URL('../', import.meta.url);
const source = readFileSync(new URL('src/worker.ts', root), 'utf8');
const moduleSource = source.replace(/import \{ neon, type NeonQueryFunction \} from "@neondatabase\/serverless";/, '')
  .replace('export default {', 'const worker = {')
  + '\nglobalThis.audit = {worker, homeStatsScript};';
const compiled = ts.transpileModule(moduleSource, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText;
const env = {
  APP_BASE_URL: 'https://cryptoscreen.app', WEB_BASE_URL: 'https://www.cryptoscreen.app',
  APPLE_TEAM_ID: 'J7C56736F3', IOS_BUNDLE_ID: 'com.domenico.privacyscreen',
  APP_CLIP_BUNDLE_ID: 'com.domenico.privacyscreen.Clip', APPLE_APP_ID: '6779173642',
  SERVER_PIN_PEPPER: 'synthetic-test-pepper', DATABASE_URL: 'synthetic',
};
function worker(sql = async () => []) {
  const context = vm.createContext({ TextEncoder, URL, Request, Response, Headers, crypto: webcrypto, console, atob, btoa, neon: () => sql });
  vm.runInContext(compiled, context);
  return context.audit;
}
const api = worker();
const temp = mkdtempSync(join(tmpdir(), 'cryptoscreen-message-test-'));
after(() => rmSync(temp, { recursive: true, force: true }));
execFileSync('xcrun', ['swiftc', 'PrivacyScreen/SealedMessageCrypto.swift', 'tests/SealedMessageFixture.swift', '-o', join(temp, 'fixture')], { cwd: root });
const fixture = JSON.parse(execFileSync(join(temp, 'fixture'), { encoding: 'utf8' }));
const messagePath = '/m/' + fixture.id;
const fragment = '#s=' + fixture.secret;
const appURL = env.APP_BASE_URL + messagePath + fragment;
const webURL = env.WEB_BASE_URL + messagePath + fragment;
const tick = () => new Promise(resolve => setImmediate(resolve));
const scripts = html => [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]);
const decode = value => value.replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&lt;', '<').replaceAll('&gt;', '>');

// Small DOM boundary for executing the real emitted scripts, Web Crypto and events.
// Browser rendering is additionally checked against a running Worker.
class Element {
  constructor(attributes = {}) { this.attributes = attributes; this.hidden = 'hidden' in attributes; this.textContent = ''; this.value = ''; this.listeners = {}; }
  get href() { return this.attributes.href; }
  set href(value) { this.attributes.href = value; }
  get content() { return this.attributes.content; }
  set content(value) { this.attributes.content = value; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  setAttribute(name, value) { this.attributes[name] = value; }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  querySelector() { return this.button ??= new Element(); }
}
async function browser(url, { userAgent = 'Mozilla/5.0 (Linux; Android 15)', platform = 'Linux', touchPoints = 1, status = { status: 'active', readPolicy: 'web_allowed' }, consume, attachmentFails = false } = {}) {
  const response = await api.worker.fetch(new Request(url), env);
  const html = await response.text();
  const elements = [...html.matchAll(/<(?:meta|a|div|section|form|input|p|pre|img|button)\b([^>]*)>/g)].map(match => {
    const attrs = Object.fromEntries([...match[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(x => [x[1], decode(x[2])]));
    if (/\shidden(?:\s|$)/.test(match[1])) attrs.hidden = '';
    for (const m of match[1].matchAll(/\b(data-[\w-]+)(?=\s|$)/g)) attrs[m[1]] = '';
    return new Element(attrs);
  });
  const selectAll = selector => {
    const m = selector.match(/^(?:meta)?\[([^=\]]+)(?:="([^"]*)")?\]$/);
    assert.ok(m, 'Unsupported test selector: ' + selector);
    return elements.filter(el => m[1] in el.attributes && (m[2] === undefined || el.attributes[m[1]] === m[2]));
  };
  const classes = new Set();
  const listeners = {};
  const document = {
    documentElement: { classList: { toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); }, contains(name) { return classes.has(name); } } },
    querySelector: selector => selectAll(selector)[0] ?? null,
    querySelectorAll: selectAll,
  };
  let redirected;
  const location = new URL(url);
  location.replace = destination => { redirected = destination; };
  const window = { location, crypto: webcrypto, addEventListener(name, fn) { listeners[name] = fn; } };
  const requests = [];
  const fetch = async (path, options = {}) => {
    requests.push({ path, ...options });
    if (path.endsWith('/status')) return { ok: true, json: async () => status };
    if (path.endsWith('/consume')) {
      if (consume) return consume(path, options);
      const proof = JSON.parse(options.body);
      assert.equal(proof.pinProof, fixture.pinProof, 'Browser PIN proof must match Swift CryptoKit');
      assert.equal(proof.readerClient, 'web');
      assert.equal(proof.clientOptIn, false);
      assert.ok(!options.body.includes(fixture.secret));
      assert.ok(!options.body.includes(fixture.pin));
      return { ok: true, json: async () => ({ ...fixture, status: 'opened', retained: false, attachment: { encryptedFileKey: fixture.encryptedFileKey, downloadPath: '/api/read-sessions/test/attachment', contentType: 'image/png' } }) };
    }
    if (path.endsWith('/attachment')) return { ok: !attachmentFails, arrayBuffer: async () => Uint8Array.from(Buffer.from(fixture.imageCiphertext, 'base64')).buffer };
    throw new Error('Unexpected network request: ' + path);
  };
  const context = vm.createContext({ window, document, navigator: { userAgent, platform, maxTouchPoints: touchPoints }, URL, URLSearchParams, crypto: webcrypto, TextEncoder, TextDecoder, Uint8Array, Blob, atob, btoa, fetch });
  const allScripts = scripts(html);
  vm.runInContext(allScripts[0], context);
  if (!redirected) {
    for (const script of allScripts.slice(1)) vm.runInContext(script, context);
    listeners.DOMContentLoaded?.();
    await tick();
  }
  const el = name => document.querySelector('[' + name + ']');
  return { html, response, el, redirected, requests, listeners, classes,
    submit: async (pin = fixture.pin) => { el('data-pin').value = pin; await el('data-browser-reader').listeners.submit({ preventDefault() {} }); },
  };
}

for (const suffix of ['', '?clip=1']) {
  test('message scripts pass the actual CSP for ' + (suffix || 'reader'), async () => {
    const response = await api.worker.fetch(new Request(env.APP_BASE_URL + messagePath + suffix), env);
    const html = await response.text();
    for (const script of [...scripts(html), ...scripts(api.homeStatsScript())]) {
      assert.ok(response.headers.get('Content-Security-Policy').includes("'sha256-" + createHash('sha256').update(script).digest('base64') + "'"));
    }
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.ok(html.includes('noindex, nofollow, noarchive'));
  });
}
test('iPhone browser fallback moves to www without sending or storing the fragment', async () => {
  const page = await browser(appURL, { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' });
  assert.equal(page.redirected, webURL);
  assert.equal(page.requests.length, 0);
  assert.ok(!page.html.includes(fixture.secret));
  assert.ok(!page.html.includes('sessionStorage'));
  assert.ok(!page.html.includes('openMessage.click()'));
});
test('iPad desktop mode uses the same app fallback', async () => {
  assert.equal((await browser(appURL, { userAgent: 'Mozilla/5.0 Macintosh', platform: 'MacIntel', touchPoints: 5 })).redirected, webURL);
});
test('www offers real cross-domain app and App Clip links with the full secret', async () => {
  const page = await browser(webURL, { userAgent: 'iPhone' });
  assert.equal(page.redirected, undefined);
  assert.equal(page.el('data-app-actions').hidden, false);
  assert.equal(page.el('data-open-message').href, appURL);
  assert.equal(page.el('data-app-clip').href, env.APP_BASE_URL + messagePath + '?clip=1' + fragment);
  assert.ok(!page.html.includes('app-clip-bundle-id='), 'www is intentionally not an associated App Clip domain');
});
test('explicit App Clip page displays the native card without redirecting away', async () => {
  const page = await browser(env.APP_BASE_URL + messagePath + '?clip=1' + fragment, { userAgent: 'iPhone' });
  assert.equal(page.redirected, undefined);
  assert.ok(page.html.includes('app-clip-display=card'));
  assert.ok(page.html.includes('app-clip-bundle-id=com.domenico.privacyscreen.Clip'));
  assert.equal(page.el('data-message-link').href, webURL);
  assert.equal(page.requests.length, 0);
});
test('Android hides iOS actions while enabling sender-approved browser reading', async () => {
  const page = await browser(appURL);
  assert.equal(page.redirected, undefined);
  assert.ok(page.classes.has('is-android'));
  assert.equal(page.el('data-app-actions').hidden, true);
  assert.equal(page.el('data-browser-reader').hidden, false);
});
test('app-only messages never expose the browser PIN form', async () => {
  const page = await browser(appURL, { status: { status: 'active', readPolicy: 'app_only' } });
  assert.equal(page.el('data-browser-reader').hidden, true);
  assert.match(page.el('data-reader-status').textContent, /App or web/);
  await page.submit();
  assert.equal(page.requests.filter(x => x.method === 'POST').length, 0);
});
test('incomplete links do not offer a destructive PIN attempt', async () => {
  const page = await browser(env.APP_BASE_URL + messagePath);
  assert.equal(page.el('data-browser-reader').hidden, true);
  assert.match(page.el('data-reader-status').textContent, /incomplete/);
});
test('browser decrypts text and image from the real Swift sender, then clears them', async () => {
  const page = await browser(appURL);
  await page.submit();
  assert.equal(page.el('data-plaintext').textContent, fixture.text);
  assert.equal(page.el('data-message-output').hidden, false);
  assert.equal(page.el('data-attachment').hidden, false);
  const blob = await fetch(page.el('data-attachment').src).then(r => r.arrayBuffer());
  assert.equal(Buffer.from(blob).toString('base64'), fixture.image);
  await page.submit();
  assert.equal(page.requests.filter(x => x.method === 'POST').length, 1);
  page.el('data-close-message').listeners.click();
  assert.equal(page.el('data-plaintext').textContent, '');
  assert.equal(page.el('data-message-output').hidden, true);
});
test('concurrent submissions consume only one PIN attempt', async () => {
  const page = await browser(appURL);
  await Promise.all([page.submit(), page.submit()]);
  assert.equal(page.requests.filter(x => x.method === 'POST').length, 1);
  page.listeners.pagehide();
});
test('wrong PIN can retry; exhausted/expired messages cannot', async () => {
  let attempt = 0;
  const page = await browser(appURL, { consume: async () => ({ ok: true, json: async () => (++attempt === 1 ? { status: 'wrong_pin', remainingAttempts: 2 } : { status: 'destroyed' }) }) });
  await page.submit();
  assert.match(page.el('data-reader-status').textContent, /2 attempts remaining/);
  assert.equal(page.el('data-browser-reader').hidden, false);
  await page.submit();
  assert.equal(page.el('data-browser-reader').hidden, true);
  await page.submit();
  assert.equal(attempt, 2);
});
test('attachment failure preserves the already-opened text', async () => {
  const page = await browser(appURL, { attachmentFails: true });
  await page.submit();
  assert.equal(page.el('data-plaintext').textContent, fixture.text);
  assert.match(page.el('data-reader-status').textContent, /text is open/);
  page.listeners.pagehide();
});
test('a consumed decryption failure does not invite another destructive attempt', async () => {
  const page = await browser(appURL, { consume: async () => ({ ok: true, json: async () => ({ ...fixture, status: 'opened', tag: 'invalid' }) }) });
  await page.submit();
  assert.equal(page.el('data-browser-reader').hidden, true);
  assert.match(page.el('data-reader-status').textContent, /consumed.*could not decrypt/);
});
test('API refuses web consumption of app-only messages before checking the PIN', async () => {
  const queries = [];
  const server = worker(async (strings) => {
    const sql = strings.join('?'); queries.push(sql);
    return sql.includes('select read_policy') ? [{ read_policy: 'app_only' }] : [];
  });
  const result = await server.worker.fetch(new Request(env.APP_BASE_URL + '/api/messages/' + fixture.id + '/consume', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pinProof: fixture.pinProof, readerClient: 'web' }) }), env);
  assert.equal(result.status, 403);
  assert.equal((await result.json()).error.code, 'app_only_message');
  assert.ok(!queries.some(sql => sql.includes('consume_sealed_message')));
});
