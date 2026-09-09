// Explicit live smoke test: creates and consumes only its own synthetic messages.
// Run with: node scripts/smoke-browser-reading.mjs https://cryptoscreen.app https://www.cryptoscreen.app
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const [appOrigin, webOrigin] = process.argv.slice(2);
if (!appOrigin || !webOrigin) throw new Error('Pass the app and browser HTTPS origins explicitly.');
for (const origin of [appOrigin, webOrigin]) assert.equal(new URL(origin).protocol, 'https:');
const temporary = mkdtempSync(join(tmpdir(), 'cryptoscreen-live-smoke-'));
const created = [];
function request(origin, path, method = 'GET', body, headers = {}) {
  const args = ['--silent', '--show-error', '--max-time', '25', '--request', method, '--write-out', '\n%{http_code}', origin + path];
  for (const [name, value] of Object.entries(headers)) args.push('--header', name + ': ' + value);
  if (body !== undefined) args.push('--data-binary', '@-');
  const output = execFileSync('curl', args, { input: body, maxBuffer: 2 * 1024 * 1024 });
  const index = output.lastIndexOf(10);
  const status = Number(output.subarray(index + 1).toString());
  const bytes = output.subarray(0, index);
  return { status, bytes, json: () => JSON.parse(bytes.toString()) };
}
const json = (origin, path, method, body) => request(origin, path, method, JSON.stringify(body), { 'Content-Type': 'application/json' });
try {
  execFileSync('xcrun', ['swiftc', 'PrivacyScreen/SealedMessageCrypto.swift', 'tests/SealedMessageFixture.swift', '-o', join(temporary, 'fixture')]);
  const f = JSON.parse(execFileSync(join(temporary, 'fixture'), { encoding: 'utf8' }));
  const create = readPolicy => {
    const response = json(appOrigin, '/api/messages', 'POST', { ciphertext: f.ciphertext, nonce: f.nonce, tag: f.tag, salt: f.salt, pinProof: f.pinProof, revokeProof: f.revokeProof, readPolicy, ttlSeconds: 300 });
    assert.equal(response.status, 201, 'Create synthetic message');
    const id = response.json().id;
    created.push({ id, proof: f.revokeProof });
    return id;
  };
  const consume = (id, readerClient, pinProof = f.pinProof) => json(webOrigin, '/api/messages/' + id + '/consume', 'POST', { pinProof, readerClient, clientOptIn: false });
  const webID = create('web_allowed');
  const attachment = request(appOrigin, '/api/messages/' + webID + '/attachment', 'PUT', Buffer.from(f.imageCiphertext, 'base64'), {
    'Content-Type': 'application/octet-stream', 'X-Cryptoscreen-Attachment-Type': 'image', 'X-Cryptoscreen-Attachment-Content-Type': 'image/png', 'X-Cryptoscreen-Encrypted-File-Key': f.encryptedFileKey,
  });
  assert.equal(attachment.status, 201, 'Upload synthetic encrypted attachment');
  const status = request(webOrigin, '/api/messages/' + webID + '/status');
  assert.equal(status.status, 200);
  assert.equal(status.json().readPolicy, 'web_allowed');
  const opened = consume(webID, 'web');
  assert.equal(opened.status, 200);
  const payload = opened.json();
  assert.equal(payload.status, 'opened');
  for (const key of ['ciphertext', 'salt', 'nonce', 'tag']) assert.equal(payload[key], f[key]);
  const image = request(webOrigin, payload.attachment.downloadPath);
  assert.equal(image.status, 200);
  assert.equal(image.bytes.toString('base64'), f.imageCiphertext);
  assert.ok(request(webOrigin, payload.attachment.downloadPath).status >= 400, 'Image must be one-time');
  assert.notEqual(consume(webID, 'web').json().status, 'opened', 'Text must be one-time');
  const appID = create('app_only');
  assert.equal(consume(appID, 'web').status, 403, 'Browser must respect sender app-only policy');
  assert.equal(consume(appID, 'ios_app').json().status, 'opened', 'Refusing browser must not consume the message');
  const wrongID = create('web_allowed');
  const wrongProof = Buffer.alloc(32).toString('base64url');
  for (const remaining of [2, 1]) {
    const result = consume(wrongID, 'web', wrongProof).json();
    assert.equal(result.status, 'wrong_pin');
    assert.equal(result.remainingAttempts, remaining);
  }
  assert.equal(consume(wrongID, 'web', wrongProof).json().status, 'destroyed');
  assert.notEqual(consume(wrongID, 'web').json().status, 'opened');
  console.log('PASS: live web policy, cross-host APIs, encrypted text/image delivery, one-time consumption, app-only refusal, and three-attempt destruction.');
} finally {
  for (const { id, proof } of created) {
    const result = json(appOrigin, '/api/messages/' + id + '/expire', 'POST', { revokeProof: proof });
    if (result.status >= 400) console.error('Synthetic cleanup returned HTTP ' + result.status + '; test rows expire after five minutes.');
  }
  rmSync(temporary, { recursive: true, force: true });
}
