/// <reference types="./worker-configuration" />

import { neon } from "@neondatabase/serverless";

const MAX_REQUEST_BYTES = 128 * 1024;
const MAX_CIPHERTEXT_BYTES = 64 * 1024;
const LINK_RETENTION_DAYS = 30;
const LINK_RETENTION_SECONDS = LINK_RETENTION_DAYS * 24 * 60 * 60;
const DEFAULT_TTL_SECONDS = LINK_RETENTION_SECONDS;
const MAX_TTL_SECONDS = LINK_RETENTION_SECONDS;
const ALPHA_LYRAE_FONT_URL = "/assets/AlphaLyrae-Medium.woff2";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BASE64URL_RE = /^[A-Za-z0-9_-]+={0,2}$/;
const consumeStatuses = ["opened", "wrong_pin", "destroyed", "expired", "unavailable"] as const;
const encoder = new TextEncoder();

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message);
  }
}

type CreateMessageBody = {
  ciphertext: string;
  nonce: string;
  tag: string;
  salt: string;
  pinProof: string;
  ttlSeconds?: number;
};

type ConsumeMessageBody = {
  pinProof: string;
};

type CreateMessageRow = {
  id: string;
  max_attempts: number;
  expires_at: string;
};

type ConsumeMessageRow = {
  status: "opened" | "wrong_pin" | "destroyed" | "expired" | "unavailable";
  remaining_attempts: number | null;
  ciphertext: string | null;
  nonce: string | null;
  tag: string | null;
  salt: string | null;
};

const securityHeaders = {
  "Content-Security-Policy":
    "default-src 'none'; img-src 'self' data:; font-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=63072000; includeSubDomains; preload",
  "X-Content-Type-Options": "nosniff"
};

const corsHeaders = {
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Max-Age": "86400"
};

export default {
  async fetch(request, env) {
    try {
      if (request.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: { ...corsHeaders, ...securityHeaders } });
      }

      const url = new URL(request.url);

      if (url.pathname === "/api/health" && request.method === "GET") {
        return await health(env);
      }

      if (url.pathname === "/api/messages" && request.method === "POST") {
        return await createMessage(request, env);
      }

      const consumeMatch = /^\/api\/messages\/([^/]+)\/consume$/.exec(url.pathname);
      if (consumeMatch && request.method === "POST") {
        return await consumeMessage(request, env, consumeMatch[1]);
      }

      if (request.method !== "GET" && request.method !== "HEAD") {
        throw new HttpError(405, "method_not_allowed", "This endpoint does not support that method.");
      }

      if (url.pathname === "/.well-known/apple-app-site-association" || url.pathname === "/apple-app-site-association") {
        return jsonResponse(appleAssociation(env), 200, {
          "Cache-Control": "public, max-age=3600",
          "Content-Type": "application/json"
        });
      }

      if (url.pathname === "/privacy") {
        return htmlResponse(privacyPage(env));
      }

      if (url.pathname === "/support") {
        return htmlResponse(supportPage(env));
      }

      if (/^\/m\/[^/]+$/.test(url.pathname)) {
        return htmlResponse(messagePage(url, env));
      }

      if (url.pathname === "/" || url.pathname === "") {
        return htmlResponse(homePage(env));
      }

      return htmlResponse(notFoundPage(env), 404);
    } catch (error) {
      if (error instanceof HttpError) {
        return jsonResponse({ error: { code: error.code, message: error.message } }, error.status);
      }

      console.error(JSON.stringify({ level: "error", message: "Unhandled request failure", error: describeError(error) }));
      return jsonResponse(
        { error: { code: "internal_error", message: "The request could not be completed." } },
        500
      );
    }
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil(deleteExpiredMessages(env));
  }
} satisfies ExportedHandler<Env>;

async function health(env: Env): Promise<Response> {
  const sql = neon(env.DATABASE_URL);
  const rows = await sql`select 1 as ok`;
  const row = parseHealthRow(rows[0]);

  return jsonResponse({
    ok: row.ok === 1,
    environment: env.ENVIRONMENT,
    service: "cryptoscreen"
  });
}

async function createMessage(request: Request, env: Env): Promise<Response> {
  const body = parseCreateBody(await readJson(request));
  const id = crypto.randomUUID();
  const ttlSeconds = clampTTL(body.ttlSeconds);
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000);
  const pinVerifierHex = bytesToHex(await pepperPinProof(base64UrlToBytes(body.pinProof, "pinProof", 32, 32), env));

  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    insert into cryptoscreen.sealed_messages (
      id,
      ciphertext,
      nonce,
      tag,
      salt,
      pin_verifier,
      max_attempts,
      expires_at
    )
    values (
      ${id}::uuid,
      decode(${base64UrlToHex(body.ciphertext, "ciphertext", 1, MAX_CIPHERTEXT_BYTES)}, 'hex'),
      decode(${base64UrlToHex(body.nonce, "nonce", 12, 12)}, 'hex'),
      decode(${base64UrlToHex(body.tag, "tag", 16, 16)}, 'hex'),
      decode(${base64UrlToHex(body.salt, "salt", 16, 16)}, 'hex'),
      decode(${pinVerifierHex}, 'hex'),
      ${3},
      ${expiresAt.toISOString()}::timestamptz
    )
    returning id::text, max_attempts, expires_at::text
  `;

  const row = parseCreateRow(rows[0]);

  return jsonResponse(
    {
      id: row.id,
      maxAttempts: row.max_attempts,
      expiresAt: expiresAt.toISOString()
    },
    201
  );
}

async function consumeMessage(request: Request, env: Env, messageID: string): Promise<Response> {
  if (!UUID_RE.test(messageID)) {
    throw new HttpError(400, "invalid_message_id", "Message id must be a UUID.");
  }

  const body = parseConsumeBody(await readJson(request));
  const pinVerifierHex = bytesToHex(await pepperPinProof(base64UrlToBytes(body.pinProof, "pinProof", 32, 32), env));
  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    select
      status::text,
      remaining_attempts,
      encode(ciphertext, 'base64') as ciphertext,
      encode(nonce, 'base64') as nonce,
      encode(tag, 'base64') as tag,
      encode(salt, 'base64') as salt
    from cryptoscreen.consume_sealed_message(${messageID}::uuid, decode(${pinVerifierHex}, 'hex'))
  `;

  const row = parseConsumeRow(rows[0]);

  if (row.status !== "opened") {
    return jsonResponse({
      status: row.status,
      remainingAttempts: row.remaining_attempts ?? 0
    });
  }

  assertColumn(row.ciphertext, "ciphertext");
  assertColumn(row.nonce, "nonce");
  assertColumn(row.tag, "tag");
  assertColumn(row.salt, "salt");

  return jsonResponse({
    status: row.status,
    remainingAttempts: row.remaining_attempts ?? 0,
    ciphertext: base64ToBase64Url(row.ciphertext),
    nonce: base64ToBase64Url(row.nonce),
    tag: base64ToBase64Url(row.tag),
    salt: base64ToBase64Url(row.salt)
  });
}

async function deleteExpiredMessages(env: Env): Promise<void> {
  const sql = neon(env.DATABASE_URL);
  await sql`select cryptoscreen.delete_expired_sealed_messages()`;
}

async function readJson(request: Request): Promise<unknown> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    throw new HttpError(415, "unsupported_media_type", "Send a JSON request body.");
  }

  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BYTES) {
    throw new HttpError(413, "request_too_large", "The request body is too large.");
  }

  const raw = await request.text();
  if (raw.length > MAX_REQUEST_BYTES) {
    throw new HttpError(413, "request_too_large", "The request body is too large.");
  }

  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpError(400, "invalid_json", "The request body must be valid JSON.");
  }
}

function parseCreateBody(value: unknown): CreateMessageBody {
  const body = expectRecord(value);
  const ttlValue = body.ttlSeconds;
  const ttlSeconds = ttlValue === undefined ? undefined : expectNumber(ttlValue, "ttlSeconds");

  return {
    ciphertext: expectString(body.ciphertext, "ciphertext"),
    nonce: expectString(body.nonce, "nonce"),
    tag: expectString(body.tag, "tag"),
    salt: expectString(body.salt, "salt"),
    pinProof: expectString(body.pinProof, "pinProof"),
    ttlSeconds
  };
}

function parseConsumeBody(value: unknown): ConsumeMessageBody {
  const body = expectRecord(value);

  return {
    pinProof: expectString(body.pinProof, "pinProof")
  };
}

function expectRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpError(400, "invalid_body", "The request body must be a JSON object.");
  }

  return value as Record<string, unknown>;
}

function expectString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new HttpError(400, "invalid_field", `${field} must be a non-empty string.`);
  }

  return value;
}

function expectNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new HttpError(400, "invalid_field", `${field} must be a finite number.`);
  }

  return value;
}

function clampTTL(value: number | undefined): number {
  if (value === undefined) {
    return DEFAULT_TTL_SECONDS;
  }

  const ttl = Math.floor(value);
  if (ttl < 60 || ttl > MAX_TTL_SECONDS) {
    throw new HttpError(400, "invalid_ttl", `ttlSeconds must be between 60 seconds and ${LINK_RETENTION_DAYS} days.`);
  }

  return ttl;
}

async function pepperPinProof(rawPinProof: Uint8Array, env: Env): Promise<Uint8Array> {
  if (env.SERVER_PIN_PEPPER.length < 32) {
    throw new HttpError(500, "server_misconfigured", "The server pepper is not configured.");
  }

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(env.SERVER_PIN_PEPPER),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const proof = new Uint8Array(rawPinProof.byteLength);
  proof.set(rawPinProof);
  const signature = await crypto.subtle.sign("HMAC", key, proof);

  return new Uint8Array(signature);
}

function base64UrlToHex(value: string, field: string, minBytes: number, maxBytes: number): string {
  return bytesToHex(base64UrlToBytes(value, field, minBytes, maxBytes));
}

function base64UrlToBytes(value: string, field: string, minBytes: number, maxBytes: number): Uint8Array {
  if (!BASE64URL_RE.test(value)) {
    throw new HttpError(400, "invalid_base64url", `${field} must be base64url encoded.`);
  }

  let base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  base64 += "=".repeat((4 - (base64.length % 4)) % 4);

  let binary: string;
  try {
    binary = atob(base64);
  } catch {
    throw new HttpError(400, "invalid_base64url", `${field} must be base64url encoded.`);
  }

  if (binary.length < minBytes || binary.length > maxBytes) {
    throw new HttpError(400, "invalid_length", `${field} has an invalid byte length.`);
  }

  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }

  return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64ToBase64Url(value: string): string {
  return value.replace(/\s+/g, "").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function assertColumn(value: string | null, column: string): asserts value is string {
  if (value === null) {
    throw new HttpError(500, "missing_ciphertext", `The consumed row did not include ${column}.`);
  }
}

function parseHealthRow(value: unknown): { ok: number } {
  const row = expectDatabaseRecord(value);
  const ok = row.ok;

  if (typeof ok !== "number") {
    throw new HttpError(500, "invalid_database_result", "Health check returned an invalid result.");
  }

  return { ok };
}

function parseCreateRow(value: unknown): CreateMessageRow {
  const row = expectDatabaseRecord(value);

  return {
    id: expectDatabaseString(row.id, "id"),
    max_attempts: expectDatabaseNumber(row.max_attempts, "max_attempts"),
    expires_at: expectDatabaseString(row.expires_at, "expires_at")
  };
}

function parseConsumeRow(value: unknown): ConsumeMessageRow {
  const row = expectDatabaseRecord(value);
  const status = expectDatabaseString(row.status, "status");

  if (!isConsumeStatus(status)) {
    throw new HttpError(500, "invalid_database_result", "Consume returned an invalid status.");
  }

  return {
    status,
    remaining_attempts: expectNullableDatabaseNumber(row.remaining_attempts, "remaining_attempts"),
    ciphertext: expectNullableDatabaseString(row.ciphertext, "ciphertext"),
    nonce: expectNullableDatabaseString(row.nonce, "nonce"),
    tag: expectNullableDatabaseString(row.tag, "tag"),
    salt: expectNullableDatabaseString(row.salt, "salt")
  };
}

function expectDatabaseRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpError(500, "invalid_database_result", "The database returned an invalid result.");
  }

  return value as Record<string, unknown>;
}

function expectDatabaseString(value: unknown, field: string): string {
  if (typeof value !== "string") {
    throw new HttpError(500, "invalid_database_result", `The database field ${field} was invalid.`);
  }

  return value;
}

function expectDatabaseNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new HttpError(500, "invalid_database_result", `The database field ${field} was invalid.`);
  }

  return value;
}

function expectNullableDatabaseString(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }

  return expectDatabaseString(value, field);
}

function expectNullableDatabaseNumber(value: unknown, field: string): number | null {
  if (value === null) {
    return null;
  }

  return expectDatabaseNumber(value, field);
}

function isConsumeStatus(value: string): value is ConsumeMessageRow["status"] {
  return consumeStatuses.includes(value as ConsumeMessageRow["status"]);
}

function jsonResponse(data: unknown, status = 200, extraHeaders: HeadersInit = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...securityHeaders,
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders
    }
  });
}

function htmlResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      ...securityHeaders,
      "Cache-Control": "public, max-age=300",
      "Content-Type": "text/html; charset=utf-8"
    }
  });
}

function appleAssociation(env: Env): unknown {
  const parentAppID = `${env.APPLE_TEAM_ID}.${env.IOS_BUNDLE_ID}`;
  const appClipID = `${env.APPLE_TEAM_ID}.${env.APP_CLIP_BUNDLE_ID}`;

  return {
    applinks: {
      apps: [],
      details: [
        {
          appIDs: [parentAppID],
          components: [
            {
              "/": "/m/*",
              comment: "Open sealed message links in cryptoscreen."
            }
          ]
        }
      ]
    },
    appclips: {
      apps: [appClipID]
    }
  };
}

function homePage(env: Env): string {
  const links = siteLinks(env);

  return pageShell(
    "cryptoscreen",
    env,
    `
      <section class="hero">
        <div class="reader-scene" aria-hidden="true">
          <div class="reader-lines top">
            <span>U7MZ /FQ6 V$L9 10RQ KQ*8</span>
            <span>DC1X 8J%4 2QFA PV37 L/0X</span>
            <span>41KR YN9Q K#L0 M44C VZ1B</span>
            <span>9AF3 P$8L DQ20 QK17 NQ#M</span>
            <span>QL50 ZJ6P 8KNR VV1X C0DE</span>
          </div>
          <div class="reveal-band">
            <span>Read one line. Move the page. Let the rest fall back.</span>
          </div>
          <div class="reader-lines bottom">
            <span>J7Y4 K%Q1 H8NN ZPL0 M2VX</span>
            <span>TY09 DKL4 C#P8 F17M XQ22</span>
            <span>Q681 41JQ B$Q 1F87 UZ5Q</span>
            <span>B*F4 %1Z ZS88 W3LZ YN07</span>
            <span>PX3D LQ12 H#6K TM0Z 88AC</span>
          </div>
        </div>
        <div class="hero-copy">
          <p class="eyebrow">One-time private reading</p>
          <h1>cryptoscreen</h1>
          <p class="lede">
            Sealed messages for iPhone. The sender encrypts locally, shares a link and PIN, and the recipient gets one controlled read before the row disappears.
          </p>
          <div class="actions">
            <a class="button primary" href="${escapeAttribute(links.appStoreUrl)}">Open on App Store</a>
            <a class="button" href="/support">Support</a>
            <a class="button ghost" href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
            <a class="button ghost" href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
          </div>
        </div>
      </section>
      <section class="section split">
        <div>
          <p class="eyebrow">What it does</p>
          <h2>Messages are sealed before they leave the phone.</h2>
        </div>
        <div class="copy-stack">
          <p>The server stores encrypted bytes, attempt metadata, and an expiry time. It does not receive the plaintext, the link secret, contact lists, or account profiles.</p>
          <p>A correct PIN consumes the message. The third wrong PIN destroys it. Unused links expire after ${LINK_RETENTION_DAYS} days.</p>
        </div>
      </section>
      <section class="section steps" aria-label="How cryptoscreen works">
        <article>
          <span>01</span>
          <h3>Seal</h3>
          <p>Write the note in the app, choose a six-digit PIN, and encrypt on device.</p>
        </article>
        <article>
          <span>02</span>
          <h3>Share</h3>
          <p>Send the link and PIN through separate channels. The URL fragment keeps the secret out of server logs.</p>
        </article>
        <article>
          <span>03</span>
          <h3>Read once</h3>
          <p>The reader reveals a narrow window, with capture redaction and no selectable plaintext.</p>
        </article>
      </section>
      <section class="section apple-strip">
        <div>
          <p class="eyebrow">Apple review links</p>
          <h2>Required public endpoints are hosted here.</h2>
        </div>
        <nav class="link-list" aria-label="Apple review">
          <a href="/privacy">Privacy Policy</a>
          <a href="/support">Support</a>
          <a href="/.well-known/apple-app-site-association">Apple association</a>
          <a href="/m/example-message-id">Universal link page</a>
        </nav>
      </section>
    `
  );
}

function messagePage(url: URL, env: Env): string {
  const messageID = escapeHtml(url.pathname.split("/").pop() ?? "");

  return pageShell(
    "Open sealed message",
    env,
    `
      <section class="panel">
        <p class="eyebrow">Sealed message</p>
        <h1>Open in cryptoscreen</h1>
        <p>
          This link points to message <code>${messageID}</code>. Open it on iPhone with cryptoscreen or the App Clip, then enter the six-digit PIN from the sender.
        </p>
        <p class="note">
          The decryption secret belongs in the URL fragment after <code>#s=</code>. Browsers do not send that fragment to this server.
        </p>
        <div class="actions">
          <a class="button primary" href="/">About cryptoscreen</a>
          <a class="button" href="/support">Support</a>
        </div>
      </section>
    `
  );
}

function privacyPage(env: Env): string {
  return pageShell(
    "Privacy Policy",
    env,
    `
      <section class="panel prose">
        <p class="eyebrow">Privacy Policy</p>
        <h1>cryptoscreen Privacy Policy</h1>
        <p>cryptoscreen is designed for one-time encrypted messages. Message plaintext is encrypted on the sender device before upload and is not stored by the service.</p>
        <h2>What the service stores</h2>
        <p>The production API stores encrypted message bytes, nonce, tag, salt, expiry time, and failed attempt count. Rows are deleted after a successful read, after the third wrong PIN, or after expiry cleanup. Unused links expire after ${LINK_RETENTION_DAYS} days.</p>
        <h2>What is not stored</h2>
        <p>The service does not intentionally store plaintext message content, the URL fragment secret, contact lists, or account profiles.</p>
        <h2>Operational data</h2>
        <p>Cloudflare and Neon may process standard infrastructure logs needed to operate, secure, and debug the service.</p>
        <h2>Contact</h2>
        <p>For privacy requests, use the contact address on the support page.</p>
      </section>
    `
  );
}

function supportPage(env: Env): string {
  const links = siteLinks(env);

  return pageShell(
    "Support",
    env,
    `
      <section class="panel prose">
        <p class="eyebrow">Support</p>
        <h1>cryptoscreen Support</h1>
        <p>For help with TestFlight builds, message links, or deletion behavior, contact <a href="mailto:${escapeAttribute(links.supportEmail)}">${escapeHtml(links.supportEmail)}</a>.</p>
        <h2>Current beta behavior</h2>
        <p>Messages delete after one successful read, after the third wrong PIN, or after ${LINK_RETENTION_DAYS} days if never opened.</p>
        <h2>Project links</h2>
        <p>
          Follow development on <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a> or contact the maintainer on <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>.
        </p>
        <h2>Safety note</h2>
        <p>Screenshot and screen recording protections are best-effort iOS protections. They reduce accidental exposure but cannot guarantee protection against external cameras or compromised devices.</p>
      </section>
    `
  );
}

function notFoundPage(env: Env): string {
  return pageShell(
    "Not found",
    env,
    `
      <section class="panel">
        <p class="eyebrow">404</p>
        <h1>Not found</h1>
        <p>This cryptoscreen URL does not exist.</p>
      </section>
    `
  );
}

function pageShell(title: string, env: Env, content: string): string {
  const escapedTitle = escapeHtml(title);
  const appID = escapeHtml(env.APPLE_APP_ID);
  const clipID = escapeHtml(env.APP_CLIP_BUNDLE_ID);
  const description = "cryptoscreen seals one-time encrypted messages for private reading on iPhone.";
  const links = siteLinks(env);

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="apple-itunes-app" content="app-id=${appID}, app-clip-bundle-id=${clipID}">
    <meta name="description" content="${escapeAttribute(description)}">
    <meta name="theme-color" content="#08100b">
    <meta property="og:title" content="${escapedTitle}">
    <meta property="og:description" content="${escapeAttribute(description)}">
    <meta property="og:type" content="website">
    <title>${escapedTitle}</title>
    <style>
      @font-face {
        font-family: "Alpha Lyrae";
        font-style: normal;
        font-weight: 500;
        font-display: swap;
        src: url("${ALPHA_LYRAE_FONT_URL}") format("woff2");
      }
      :root {
        color-scheme: dark;
        --bg: oklch(7% 0.014 154);
        --bg-2: oklch(10.5% 0.018 154);
        --panel: oklch(14.5% 0.018 154);
        --panel-2: oklch(18% 0.02 154);
        --ink: oklch(94% 0.018 96);
        --soft-ink: oklch(79% 0.02 116);
        --muted: oklch(67% 0.026 135);
        --quiet: oklch(50% 0.024 145);
        --line: oklch(94% 0.018 96 / 0.13);
        --line-strong: oklch(94% 0.018 96 / 0.22);
        --accent: oklch(79% 0.21 152);
        --accent-ink: oklch(16% 0.06 153);
        --warn: oklch(78% 0.15 77);
        --blue: oklch(77% 0.1 240);
      }
      * { box-sizing: border-box; }
      html { background: var(--bg); }
      body {
        margin: 0;
        min-height: 100vh;
        background: var(--bg);
        color: var(--ink);
        font-family: ui-monospace, "SFMono-Regular", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
        text-rendering: optimizeLegibility;
      }
      a { color: var(--blue); text-underline-offset: 0.18em; }
      code { color: var(--accent); font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace; }
      .wrap {
        width: min(1120px, calc(100% - 32px));
        margin: 0 auto;
        padding: 18px 0 44px;
      }
      header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 16px;
        padding: 10px 0 18px;
      }
      .brand {
        color: var(--ink);
        font-family: "Alpha Lyrae", ui-rounded, "SF Pro Rounded", ui-sans-serif, system-ui, sans-serif;
        font-size: 18px;
        font-weight: 500;
        letter-spacing: 0;
        text-decoration: none;
      }
      nav {
        display: flex;
        flex-wrap: wrap;
        gap: 10px 16px;
        font-size: 14px;
      }
      nav a {
        color: var(--muted);
        text-decoration: none;
      }
      nav a:hover, .brand:hover { color: var(--ink); }
      .hero {
        position: relative;
        min-height: min(760px, calc(100vh - 96px));
        display: flex;
        align-items: end;
        overflow: hidden;
        border: 1px solid var(--line);
        border-radius: 8px;
        background: var(--bg-2);
        isolation: isolate;
      }
      .hero::after {
        content: "";
        position: absolute;
        inset: 0;
        background:
          linear-gradient(180deg, oklch(7% 0.014 154 / 0.12), var(--bg) 95%),
          linear-gradient(90deg, var(--bg) 0%, oklch(7% 0.014 154 / 0.76) 36%, oklch(7% 0.014 154 / 0.18) 100%);
        z-index: -1;
      }
      .hero-copy {
        max-width: 760px;
        padding: clamp(28px, 7vw, 78px);
      }
      .eyebrow {
        color: var(--accent);
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0;
        margin: 0 0 14px;
        text-transform: uppercase;
      }
      h1 {
        font-family: "Alpha Lyrae", ui-rounded, "SF Pro Rounded", ui-sans-serif, system-ui, sans-serif;
        font-size: clamp(44px, 11vw, 104px);
        font-feature-settings: "calt" 1, "liga" 1;
        font-weight: 500;
        line-height: 0.94;
        letter-spacing: 0;
        margin: 0 0 20px;
      }
      h2 {
        color: var(--ink);
        font-family: "Alpha Lyrae", ui-rounded, "SF Pro Rounded", ui-sans-serif, system-ui, sans-serif;
        font-size: clamp(26px, 5vw, 48px);
        font-feature-settings: "calt" 1, "liga" 1;
        font-weight: 500;
        line-height: 1.02;
        letter-spacing: 0;
        margin: 0;
      }
      h3 {
        color: var(--ink);
        font-family: "Alpha Lyrae", ui-rounded, "SF Pro Rounded", ui-sans-serif, system-ui, sans-serif;
        font-size: 22px;
        font-feature-settings: "calt" 1, "liga" 1;
        font-weight: 500;
        line-height: 1.1;
        margin: 10px 0 8px;
      }
      p {
        color: var(--muted);
        font-size: 16px;
        line-height: 1.65;
        margin: 0;
      }
      .lede {
        color: var(--soft-ink);
        font-size: clamp(18px, 3.2vw, 24px);
        line-height: 1.45;
        max-width: 650px;
      }
      .actions {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        margin-top: 28px;
      }
      .button {
        border: 1px solid var(--line);
        border-radius: 8px;
        color: var(--ink);
        display: inline-flex;
        align-items: center;
        justify-content: center;
        font-weight: 700;
        min-height: 44px;
        padding: 11px 15px;
        text-decoration: none;
        transition: background 160ms ease-out, border-color 160ms ease-out, color 160ms ease-out;
      }
      .button.primary {
        background: var(--accent);
        border-color: var(--accent);
        color: var(--accent-ink);
      }
      .button.ghost {
        color: var(--soft-ink);
      }
      .button:hover {
        background: var(--panel-2);
        border-color: var(--line-strong);
      }
      .button.primary:hover {
        background: oklch(85% 0.2 152);
        color: var(--accent-ink);
      }
      .reader-scene {
        position: absolute;
        inset: 0;
        z-index: -2;
        display: grid;
        grid-template-rows: 1fr auto 1fr;
        padding: clamp(28px, 5vw, 64px);
        opacity: 0.9;
      }
      .reader-lines {
        display: grid;
        align-content: center;
        gap: clamp(8px, 1.8vw, 18px);
        min-width: 760px;
        margin-left: clamp(120px, 28vw, 390px);
        font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
        font-size: clamp(17px, 2.7vw, 35px);
        line-height: 1.1;
        color: oklch(91% 0.02 116 / 0.24);
        white-space: nowrap;
      }
      .reader-lines span {
        display: block;
      }
      .reveal-band {
        display: grid;
        align-items: center;
        min-height: clamp(72px, 18vw, 168px);
        margin: 0 calc(clamp(28px, 5vw, 64px) * -1);
        padding-left: clamp(180px, 36vw, 520px);
        background: oklch(79% 0.21 152 / 0.08);
        border-block: 1px solid oklch(79% 0.21 152 / 0.22);
        box-shadow: 0 0 80px oklch(79% 0.21 152 / 0.13);
        font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
        font-size: clamp(18px, 3.6vw, 44px);
        font-weight: 700;
        line-height: 1.15;
        color: var(--ink);
        white-space: nowrap;
      }
      .section {
        padding: clamp(42px, 9vw, 96px) 0;
      }
      .split {
        display: grid;
        grid-template-columns: minmax(0, 0.82fr) minmax(0, 1fr);
        gap: clamp(28px, 8vw, 96px);
        align-items: start;
      }
      .copy-stack {
        display: grid;
        gap: 18px;
        max-width: 650px;
      }
      .steps {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 12px;
      }
      article {
        border: 1px solid var(--line);
        border-radius: 8px;
        background: var(--panel);
        padding: 22px;
      }
      article span {
        color: var(--accent);
        font-size: 13px;
        font-weight: 800;
      }
      article p {
        font-size: 15px;
      }
      .apple-strip {
        border-top: 1px solid var(--line);
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(220px, 360px);
        gap: 28px;
      }
      .link-list {
        display: grid;
        align-content: start;
        gap: 10px;
        font-size: 16px;
      }
      .link-list a {
        border: 1px solid var(--line);
        border-radius: 8px;
        color: var(--soft-ink);
        padding: 13px 14px;
        text-decoration: none;
      }
      .link-list a:hover {
        border-color: var(--line-strong);
        color: var(--ink);
      }
      .panel {
        border: 1px solid var(--line);
        border-radius: 8px;
        background: var(--panel);
        padding: clamp(24px, 6vw, 46px);
        max-width: 760px;
        margin: 0 auto;
      }
      .prose h1 {
        font-size: clamp(36px, 8vw, 64px);
        line-height: 0.98;
      }
      .prose h2 { font-size: 24px; margin: 30px 0 10px; }
      .prose p + p { margin-top: 16px; }
      .note {
        border: 1px solid oklch(79% 0.21 152 / 0.28);
        border-radius: 8px;
        background: oklch(79% 0.21 152 / 0.06);
        color: var(--soft-ink);
        margin-top: 18px;
        padding: 14px;
      }
      footer {
        border-top: 1px solid var(--line);
        color: var(--muted);
        display: flex;
        flex-wrap: wrap;
        justify-content: space-between;
        gap: 10px 18px;
        font-size: 12px;
        margin-top: 8px;
        padding-top: 22px;
      }
      footer a {
        color: var(--muted);
        text-decoration: none;
      }
      footer a:hover {
        color: var(--ink);
      }
      @media (max-width: 760px) {
        .wrap { width: min(100% - 24px, 1120px); padding-top: 12px; }
        header { align-items: flex-start; flex-direction: column; }
        .hero { min-height: 650px; }
        .hero::after {
          background:
            linear-gradient(180deg, oklch(7% 0.014 154 / 0.04), var(--bg) 98%),
            linear-gradient(90deg, var(--bg) 0%, oklch(7% 0.014 154 / 0.78) 68%, oklch(7% 0.014 154 / 0.26) 100%);
        }
        .hero-copy { padding: 24px; }
        .actions { align-items: stretch; flex-direction: column; }
        .button { width: 100%; }
        .reader-scene { padding: 24px 16px; }
        .reader-lines {
          min-width: 560px;
          margin-left: 124px;
          font-size: 24px;
        }
        .reveal-band {
          min-height: 112px;
          padding-left: 135px;
          font-size: 28px;
        }
        .split, .steps, .apple-strip { grid-template-columns: 1fr; }
        .section { padding: 42px 0; }
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <header>
        <a class="brand" href="/">cryptoscreen</a>
        <nav aria-label="Main">
          <a href="/privacy">Privacy</a>
          <a href="/support">Support</a>
          <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
          <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
          <a href="/.well-known/apple-app-site-association">AASA</a>
        </nav>
      </header>
      <main>${content}</main>
      <footer>
        <span>cryptoscreen.app, one-time encrypted message beta</span>
        <span>
          <a href="/privacy">Privacy</a>
          &nbsp;/&nbsp;
          <a href="/support">Support</a>
          &nbsp;/&nbsp;
          <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
          &nbsp;/&nbsp;
          <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
        </span>
      </footer>
    </div>
  </body>
</html>`;
}

function siteLinks(env: Env): {
  appStoreUrl: string;
  githubUrl: string;
  supportEmail: string;
  xUrl: string;
} {
  const vars = env as unknown as Record<string, string | undefined>;

  return {
    appStoreUrl: externalUrl(`https://apps.apple.com/app/id${env.APPLE_APP_ID}`),
    githubUrl: externalUrl(vars.GITHUB_REPOSITORY_URL ?? "https://github.com/DomenicoDD/cryptoscreen"),
    supportEmail: emailAddress(vars.SUPPORT_EMAIL ?? "domenico@cryptoscreen.app"),
    xUrl: externalUrl(vars.X_PROFILE_URL ?? "https://x.com/DomenicoDD")
  };
}

function externalUrl(value: string): string {
  try {
    const url = new URL(value);
    if (url.protocol === "https:") {
      return url.toString();
    }
  } catch {
    // Fall through to a safe same-origin target.
  }

  return "/";
}

function emailAddress(value: string): string {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) ? value : "domenico@cryptoscreen.app";
}

function escapeAttribute(value: string): string {
  return escapeHtml(value);
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function describeError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
