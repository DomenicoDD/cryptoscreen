/// <reference types="./worker-configuration" />

import { neon, type NeonQueryFunction } from "@neondatabase/serverless";

const MAX_REQUEST_BYTES = 128 * 1024;
const MAX_CIPHERTEXT_BYTES = 64 * 1024;
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
const MAX_ENCRYPTED_FILE_KEY_BYTES = 128;
const LINK_RETENTION_DAYS = 30;
const LINK_RETENTION_SECONDS = LINK_RETENTION_DAYS * 24 * 60 * 60;
const DEFAULT_TTL_SECONDS = LINK_RETENTION_SECONDS;
const MAX_TTL_SECONDS = LINK_RETENTION_SECONDS;
const READ_SESSION_TTL_SECONDS = 5 * 60;
const MAX_FEEDBACK_MESSAGE_CHARS = 2_000;
const MAX_FEEDBACK_METADATA_CHARS = 180;
const MAX_FEEDBACK_TIMESTAMP_CHARS = 64;
const ALPHA_LYRAE_FONT_URL = "/assets/AlphaLyrae-Medium.woff2";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BASE64URL_RE = /^[A-Za-z0-9_-]+={0,2}$/;
const consumeStatuses = ["opened", "wrong_pin", "destroyed", "expired", "unavailable"] as const;
const messageStatuses = ["active", "expired", "consumed", "destroyed"] as const;
const attachmentContentTypes = ["image/jpeg", "image/png", "image/heic", "image/heif"] as const;
const readSessionEventTypes = ["screenshot"] as const;
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
  revokeProof?: string;
  ttlSeconds?: number;
};

type ConsumeMessageBody = {
  pinProof: string;
  clientOptIn: boolean;
};

type ExpireMessageBody = {
  revokeProof: string;
};

type FeedbackBody = {
  rating: number;
  message: string;
  appVersion?: string;
  buildNumber?: string;
  platform?: string;
  device?: string;
  timestamp: string;
};

type ReadSessionEventBody = {
  type: "screenshot";
  timestamp: string;
  clientOptIn: true;
};

type CreateMessageRow = {
  id: string;
  max_attempts: number;
  expires_at: string;
};

type ConsumeMessageRow = {
  status: "opened" | "wrong_pin" | "destroyed" | "expired" | "unavailable";
  remaining_attempts: number | null;
  retained: boolean | null;
  ciphertext: string | null;
  nonce: string | null;
  tag: string | null;
  salt: string | null;
  attachment_id: string | null;
  attachment_object_key: string | null;
  attachment_type: "image" | null;
  attachment_content_type: AttachmentContentType | null;
  attachment_ciphertext_bytes: number | null;
  attachment_encrypted_file_key: string | null;
};

type MessageStatusRow = {
  status: (typeof messageStatuses)[number];
  interactionStatusShared: boolean;
  textConsumed: boolean;
  imageAttachmentAttached: boolean;
  imageAttachmentConsumed: boolean;
  screenshotDetected: boolean;
};

type AttachmentContentType = (typeof attachmentContentTypes)[number];

type AttachmentMetadataRow = {
  id: string;
  expires_at: string;
};

type MessageAttachmentStateRow = {
  expires_at: string | null;
  has_attachment: boolean;
};

type ReadSessionRow = {
  message_id: string;
  object_key: string;
  content_type: AttachmentContentType;
  ciphertext_bytes: number;
};

type MessageStats = {
  sharedMessages: number;
  imageAttachmentsShared: number;
  updatedAt: string | null;
};

type SqlClient = NeonQueryFunction<false, false>;

let messageStatsSchemaReady: Promise<void> | null = null;

const securityHeaders = {
  "Content-Security-Policy":
    "default-src 'none'; img-src 'self' data:; font-src 'self'; style-src 'unsafe-inline'; script-src 'sha256-L0mMwZH2Y8BB9JbniZ5Xbk2cWIpVpMQyZCg7II8HSNM=' 'sha256-jV/YTTPdPdYxQ4KasU5NffuPLChgovdtiYvck0B/a0Q='; connect-src 'self'; manifest-src 'self'; frame-src https://github.com; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=63072000; includeSubDomains; preload",
  "X-Content-Type-Options": "nosniff"
};

const corsHeaders = {
  "Access-Control-Allow-Headers": "content-type, x-cryptoscreen-attachment-type, x-cryptoscreen-attachment-content-type, x-cryptoscreen-encrypted-file-key",
  "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
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

      if (url.pathname === "/api/stats" && request.method === "GET") {
        return await stats(env);
      }

      if (url.pathname === "/api/feedback" && request.method === "POST") {
        return await submitFeedback(request, env);
      }

      if (url.pathname === "/api/messages" && request.method === "POST") {
        return await createMessage(request, env);
      }

      const attachmentUploadMatch = /^\/api\/messages\/([^/]+)\/attachment$/.exec(url.pathname);
      if (attachmentUploadMatch && request.method === "PUT") {
        return await uploadMessageAttachment(request, env, attachmentUploadMatch[1]);
      }

      const statusMatch = /^\/api\/messages\/([^/]+)\/status$/.exec(url.pathname);
      if (statusMatch && request.method === "GET") {
        return await messageStatus(env, statusMatch[1]);
      }

      const expireMatch = /^\/api\/messages\/([^/]+)\/expire$/.exec(url.pathname);
      if (expireMatch && request.method === "POST") {
        return await expireMessage(request, env, expireMatch[1]);
      }

      const messageEventMatch = /^\/api\/messages\/([^/]+)\/events$/.exec(url.pathname);
      if (messageEventMatch && request.method === "POST") {
        return await recordMessageEvent(request, env, messageEventMatch[1]);
      }

      const consumeMatch = /^\/api\/messages\/([^/]+)\/consume$/.exec(url.pathname);
      if (consumeMatch && request.method === "POST") {
        return await consumeMessage(request, env, consumeMatch[1]);
      }

      const readSessionAttachmentMatch = /^\/api\/read-sessions\/([^/]+)\/attachment$/.exec(url.pathname);
      if (readSessionAttachmentMatch && request.method === "GET") {
        return await downloadReadSessionAttachment(env, readSessionAttachmentMatch[1]);
      }

      const readSessionEventMatch = /^\/api\/read-sessions\/([^/]+)\/events$/.exec(url.pathname);
      if (readSessionEventMatch && request.method === "POST") {
        return await recordReadSessionEvent(request, env, readSessionEventMatch[1]);
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

      if (url.pathname === "/terms") {
        return htmlResponse(termsPage(env));
      }

      if (url.pathname === "/security") {
        return htmlResponse(securityPage(env));
      }

      if (url.pathname === "/support") {
        return htmlResponse(supportPage(env));
      }

      if (/^\/m\/[^/]+$/.test(url.pathname)) {
        return htmlResponse(messagePage(url, env), 200, "no-store");
      }

      if (url.pathname === "/" || url.pathname === "") {
        return htmlResponse(await homePage(env));
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

async function stats(env: Env): Promise<Response> {
  return jsonResponse(await getMessageStats(env), 200, {
    "Cache-Control": "no-store"
  });
}

async function getMessageStats(env: Env): Promise<MessageStats> {
  const sql = neon(env.DATABASE_URL);
  await ensureMessageStatsSchema(sql);

  const rows = await sql`
    select
      coalesce(
        (select shared_messages from cryptoscreen.message_stats where id = true),
        0
      )::text as shared_messages,
      coalesce(
        (select image_attachments_shared from cryptoscreen.message_stats where id = true),
        0
      )::text as image_attachments_shared,
      (
        select updated_at::text
        from cryptoscreen.message_stats
        where id = true
      ) as updated_at
  `;

  return parseMessageStatsRow(rows[0]);
}

async function ensureMessageStatsSchema(sql: SqlClient): Promise<void> {
  if (!messageStatsSchemaReady) {
    messageStatsSchemaReady = applyMessageStatsSchema(sql).catch((error) => {
      messageStatsSchemaReady = null;
      throw error;
    });
  }

  await messageStatsSchemaReady;
}

async function applyMessageStatsSchema(sql: SqlClient): Promise<void> {
  await sql`
    alter table cryptoscreen.message_stats
      add column if not exists image_attachments_shared bigint not null default 0
  `;

  await sql`
    insert into cryptoscreen.message_stats (id, shared_messages, image_attachments_shared)
    values (true, 0, 0)
    on conflict (id) do nothing
  `;

  await sql`
    create or replace function cryptoscreen.record_image_attachment_shared()
    returns trigger
    language plpgsql
    security definer
    set search_path = cryptoscreen, pg_temp
    as $$
    begin
      insert into cryptoscreen.message_stats (id, shared_messages, image_attachments_shared, updated_at)
      values (true, 0, 1, now())
      on conflict (id) do update
      set
        image_attachments_shared = cryptoscreen.message_stats.image_attachments_shared + 1,
        updated_at = now();

      return new;
    end;
    $$
  `;

  await sql`
    do $$
    begin
      create trigger sealed_message_attachments_record_shared
      after insert on cryptoscreen.sealed_message_attachments
      for each row
      execute function cryptoscreen.record_image_attachment_shared();
    exception
      when duplicate_object then null;
    end;
    $$
  `;

  await sql`
    with image_messages as (
      select message_id
      from cryptoscreen.sealed_message_delivery_audit
      where has_image_attachment
      union
      select message_id
      from cryptoscreen.sealed_message_attachments
      where attachment_type = 'image'
    ),
    image_count as (
      select count(*)::bigint as value
      from image_messages
    )
    update cryptoscreen.message_stats
    set
      image_attachments_shared = greatest(image_attachments_shared, image_count.value),
      updated_at = case
        when image_attachments_shared < image_count.value then now()
        else updated_at
      end
    from image_count
    where id = true
  `;
}

async function safeMessageStats(env: Env): Promise<MessageStats | null> {
  try {
    return await getMessageStats(env);
  } catch (error) {
    console.error(JSON.stringify({ level: "error", message: "Unable to load message stats", error: describeError(error) }));
    return null;
  }
}

async function submitFeedback(request: Request, env: Env): Promise<Response> {
  const body = parseFeedbackBody(await readJson(request));
  await sendFeedbackEmail(body, env);

  return jsonResponse({ ok: true }, 202, {
    "Cache-Control": "no-store"
  });
}

async function createMessage(request: Request, env: Env): Promise<Response> {
  const body = parseCreateBody(await readJson(request));
  const id = crypto.randomUUID();
  const ttlSeconds = clampTTL(body.ttlSeconds);
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000);
  const pinVerifierHex = bytesToHex(await pepperPinProof(base64UrlToBytes(body.pinProof, "pinProof", 32, 32), env));
  const revokeVerifierHex = body.revokeProof === undefined
    ? null
    : bytesToHex(await pepperPinProof(base64UrlToBytes(body.revokeProof, "revokeProof", 32, 32), env));

  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    insert into cryptoscreen.sealed_messages (
      id,
      ciphertext,
      nonce,
      tag,
      salt,
      pin_verifier,
      revoke_verifier,
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
      decode(${revokeVerifierHex}, 'hex'),
      ${3},
      ${expiresAt.toISOString()}::timestamptz
    )
    returning id::text, max_attempts, expires_at::text
  `;

  const row = parseCreateRow(rows[0]);

  await sql`
    insert into cryptoscreen.sealed_message_delivery_audit (message_id, created_at, updated_at)
    values (${row.id}::uuid, now(), now())
    on conflict (message_id) do nothing
  `;

  return jsonResponse(
    {
      id: row.id,
      maxAttempts: row.max_attempts,
      expiresAt: expiresAt.toISOString()
    },
    201
  );
}

async function uploadMessageAttachment(request: Request, env: Env, messageID: string): Promise<Response> {
  if (!UUID_RE.test(messageID)) {
    throw new HttpError(400, "invalid_message_id", "Message id must be a UUID.");
  }

  const requestContentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!requestContentType.includes("application/octet-stream")) {
    throw new HttpError(415, "unsupported_media_type", "Upload encrypted attachment bytes as application/octet-stream.");
  }

  const attachmentType = request.headers.get("x-cryptoscreen-attachment-type")?.trim().toLowerCase();
  if (attachmentType !== "image") {
    throw new HttpError(400, "invalid_attachment_type", "Only encrypted image attachments are supported.");
  }

  const contentType = parseAttachmentContentType(request.headers.get("x-cryptoscreen-attachment-content-type"));
  const encryptedFileKey = expectHeader(request.headers.get("x-cryptoscreen-encrypted-file-key"), "x-cryptoscreen-encrypted-file-key");
  const encryptedFileKeyHex = base64UrlToHex(encryptedFileKey, "encryptedFileKey", 60, MAX_ENCRYPTED_FILE_KEY_BYTES);
  const attachmentBytes = await readAttachmentBytes(request);

  const sql = neon(env.DATABASE_URL);
  const stateRows = await sql`
    with active_message as (
      select id, expires_at
      from cryptoscreen.sealed_messages
      where id = ${messageID}::uuid
        and not retained
        and expires_at > now()
      limit 1
    )
    select
      (select expires_at::text from active_message) as expires_at,
      exists (
        select 1
        from cryptoscreen.sealed_message_attachments
        where message_id = ${messageID}::uuid
      ) as has_attachment
  `;
  const state = parseMessageAttachmentStateRow(stateRows[0]);
  if (state.expires_at === null) {
    throw new HttpError(404, "message_unavailable", "No active normal message exists for this attachment upload.");
  }
  if (state.has_attachment) {
    throw new HttpError(409, "attachment_exists", "This message already has an attachment.");
  }

  const attachmentID = crypto.randomUUID();
  const objectKey = `attachments/${messageID}/${attachmentID}.bin`;
  const bucket = attachmentBucket(env);

  await bucket.put(objectKey, attachmentBytes, {
    httpMetadata: {
      contentType: "application/octet-stream"
    },
    customMetadata: {
      attachmentType,
      declaredContentType: contentType
    }
  });

  try {
    const rows = await sql`
      insert into cryptoscreen.sealed_message_attachments (
        id,
        message_id,
        object_key,
        attachment_type,
        content_type,
        ciphertext_bytes,
        encrypted_file_key,
        expires_at
      )
      values (
        ${attachmentID}::uuid,
        ${messageID}::uuid,
        ${objectKey},
        'image',
        ${contentType},
        ${attachmentBytes.byteLength},
        decode(${encryptedFileKeyHex}, 'hex'),
        ${state.expires_at}::timestamptz
      )
      returning id::text, expires_at::text
    `;
    const row = parseAttachmentMetadataRow(rows[0]);

    await sql`
      update cryptoscreen.sealed_message_delivery_audit
      set
        has_image_attachment = true,
        updated_at = now()
      where message_id = ${messageID}::uuid
    `;

    return jsonResponse(
      {
        id: row.id,
        type: "image",
        contentType,
        byteLength: attachmentBytes.byteLength,
        expiresAt: row.expires_at
      },
      201,
      {
        "Cache-Control": "no-store"
      }
    );
  } catch (error) {
    await bucket.delete(objectKey);
    console.error(JSON.stringify({ level: "error", message: "Attachment metadata insert failed", error: describeError(error) }));
    throw new HttpError(409, "attachment_not_saved", "The encrypted attachment could not be attached to this message.");
  }
}

async function consumeMessage(request: Request, env: Env, messageID: string): Promise<Response> {
  if (!UUID_RE.test(messageID)) {
    throw new HttpError(400, "invalid_message_id", "Message id must be a UUID.");
  }

  const body = parseConsumeBody(await readJson(request));
  const pinVerifierHex = bytesToHex(await pepperPinProof(base64UrlToBytes(body.pinProof, "pinProof", 32, 32), env));
  const row = await consumeMessageRow(env, messageID, pinVerifierHex);

  if (row.status !== "opened") {
    await updateAuditForConsumeResult(env, messageID, row, body.clientOptIn);

    return jsonResponse({
      status: row.status,
      remainingAttempts: row.remaining_attempts ?? 0,
      retained: row.retained ?? false
    });
  }

  assertColumn(row.ciphertext, "ciphertext");
  assertColumn(row.nonce, "nonce");
  assertColumn(row.tag, "tag");
  assertColumn(row.salt, "salt");
  const attachment = row.retained
    ? null
    : await createReadSessionForAttachment(env, messageID, row);
  await updateAuditForConsumeResult(env, messageID, row, body.clientOptIn);

  return jsonResponse({
    status: row.status,
    remainingAttempts: row.remaining_attempts ?? 0,
    retained: row.retained ?? false,
    ciphertext: base64ToBase64Url(row.ciphertext),
    nonce: base64ToBase64Url(row.nonce),
    tag: base64ToBase64Url(row.tag),
    salt: base64ToBase64Url(row.salt),
    eventPath: `/api/messages/${messageID}/events`,
    attachment
  });
}

async function updateAuditForConsumeResult(env: Env, messageID: string, row: ConsumeMessageRow, sharesInteractionStatus: boolean): Promise<void> {
  const sql = neon(env.DATABASE_URL);

  if (row.status === "opened") {
    await sql`
      update cryptoscreen.sealed_message_delivery_audit
      set
        text_consumed_at = coalesce(text_consumed_at, now()),
        interaction_status_opted_in_at = case
          when ${sharesInteractionStatus} then coalesce(interaction_status_opted_in_at, now())
          else interaction_status_opted_in_at
        end,
        has_image_attachment = has_image_attachment or ${row.attachment_id !== null},
        updated_at = now()
      where message_id = ${messageID}::uuid
    `;
    return;
  }

  if (row.status === "expired") {
    await sql`
      update cryptoscreen.sealed_message_delivery_audit
      set
        expired_at = coalesce(expired_at, now()),
        updated_at = now()
      where message_id = ${messageID}::uuid
    `;
    return;
  }

  if (row.status === "destroyed") {
    await sql`
      update cryptoscreen.sealed_message_delivery_audit
      set
        destroyed_at = coalesce(destroyed_at, now()),
        updated_at = now()
      where message_id = ${messageID}::uuid
    `;
  }
}

async function consumeMessageRow(
  env: Env,
  messageID: string,
  pinVerifierHex: string
): Promise<ConsumeMessageRow> {
  const sql = neon(env.DATABASE_URL);

  try {
    const rows = await sql`
      select
        status::text,
        remaining_attempts,
        retained,
        encode(ciphertext, 'base64') as ciphertext,
        encode(nonce, 'base64') as nonce,
        encode(tag, 'base64') as tag,
        encode(salt, 'base64') as salt,
        attachment_id::text,
        attachment_object_key,
        attachment_type,
        attachment_content_type,
        attachment_ciphertext_bytes,
        encode(attachment_encrypted_file_key, 'base64') as attachment_encrypted_file_key
      from cryptoscreen.consume_sealed_message(${messageID}::uuid, decode(${pinVerifierHex}, 'hex'))
    `;

    return parseConsumeRow(rows[0]);
  } catch (error) {
    console.error(JSON.stringify({ level: "warn", message: "Attachment consume path unavailable; trying retained legacy path", error: describeError(error) }));
  }

  try {
    const rows = await sql`
      select
        status::text,
        remaining_attempts,
        retained,
        encode(ciphertext, 'base64') as ciphertext,
        encode(nonce, 'base64') as nonce,
        encode(tag, 'base64') as tag,
        encode(salt, 'base64') as salt
      from cryptoscreen.consume_sealed_message(${messageID}::uuid, decode(${pinVerifierHex}, 'hex'))
    `;

    return parseConsumeRowWithoutAttachment(rows[0]);
  } catch (error) {
    console.error(JSON.stringify({ level: "warn", message: "Retained consume path unavailable; trying V1 legacy path", error: describeError(error) }));
  }

  const rows = await sql`
    select
      status::text,
      remaining_attempts,
      false as retained,
      encode(ciphertext, 'base64') as ciphertext,
      encode(nonce, 'base64') as nonce,
      encode(tag, 'base64') as tag,
      encode(salt, 'base64') as salt
    from cryptoscreen.consume_sealed_message(${messageID}::uuid, decode(${pinVerifierHex}, 'hex'))
  `;

  return parseConsumeRowWithoutAttachment(rows[0]);
}

async function createReadSessionForAttachment(
  env: Env,
  messageID: string,
  row: ConsumeMessageRow
): Promise<{
  id: string;
  type: "image";
  contentType: AttachmentContentType;
  byteLength: number;
  encryptedFileKey: string;
  downloadPath: string;
  eventPath: string;
  expiresAt: string;
} | null> {
  if (
    row.attachment_id === null ||
    row.attachment_object_key === null ||
    row.attachment_type === null ||
    row.attachment_content_type === null ||
    row.attachment_ciphertext_bytes === null ||
    row.attachment_encrypted_file_key === null
  ) {
    return null;
  }

  const readSessionID = crypto.randomUUID();
  const expiresAt = new Date(Date.now() + READ_SESSION_TTL_SECONDS * 1000).toISOString();
  const encryptedFileKeyBase64Url = base64ToBase64Url(row.attachment_encrypted_file_key);
  const encryptedFileKeyHex = base64UrlToHex(
    encryptedFileKeyBase64Url,
    "attachmentEncryptedFileKey",
    60,
    MAX_ENCRYPTED_FILE_KEY_BYTES
  );
  const sql = neon(env.DATABASE_URL);

  await sql`
    insert into cryptoscreen.sealed_message_read_sessions (
      id,
      message_id,
      attachment_id,
      object_key,
      attachment_type,
      content_type,
      ciphertext_bytes,
      encrypted_file_key,
      expires_at
    )
    values (
      ${readSessionID}::uuid,
      ${messageID}::uuid,
      ${row.attachment_id}::uuid,
      ${row.attachment_object_key},
      ${row.attachment_type},
      ${row.attachment_content_type},
      ${row.attachment_ciphertext_bytes},
      decode(${encryptedFileKeyHex}, 'hex'),
      ${expiresAt}::timestamptz
    )
  `;

  return {
    id: readSessionID,
    type: "image",
    contentType: row.attachment_content_type,
    byteLength: row.attachment_ciphertext_bytes,
    encryptedFileKey: encryptedFileKeyBase64Url,
    downloadPath: `/api/read-sessions/${readSessionID}/attachment`,
    eventPath: `/api/read-sessions/${readSessionID}/events`,
    expiresAt
  };
}

async function downloadReadSessionAttachment(env: Env, readSessionID: string): Promise<Response> {
  if (!UUID_RE.test(readSessionID)) {
    throw new HttpError(400, "invalid_read_session_id", "Read session id must be a UUID.");
  }

  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    update cryptoscreen.sealed_message_read_sessions
    set consumed_at = now()
    where id = ${readSessionID}::uuid
      and consumed_at is null
      and expires_at > now()
    returning
      message_id::text,
      object_key,
      content_type,
      ciphertext_bytes
  `;
  if (rows.length === 0) {
    throw new HttpError(410, "read_session_unavailable", "This attachment read session is no longer available.");
  }

  const row = parseReadSessionRow(rows[0]);
  const bucket = attachmentBucket(env);
  const object = await bucket.get(row.object_key);
  if (object === null) {
    throw new HttpError(410, "attachment_unavailable", "The encrypted attachment is no longer available.");
  }

  const body = await object.arrayBuffer();
  await bucket.delete(row.object_key);
  await sql`
    update cryptoscreen.sealed_message_delivery_audit
    set
      has_image_attachment = true,
      image_consumed_at = coalesce(image_consumed_at, now()),
      updated_at = now()
    where message_id = ${row.message_id}::uuid
  `;

  return new Response(body, {
    status: 200,
    headers: {
      ...securityHeaders,
      ...corsHeaders,
      "Cache-Control": "no-store",
      "Content-Length": String(body.byteLength),
      "Content-Type": "application/octet-stream",
      "X-Content-Type-Options": "nosniff"
    }
  });
}

async function recordReadSessionEvent(request: Request, env: Env, readSessionID: string): Promise<Response> {
  if (!UUID_RE.test(readSessionID)) {
    throw new HttpError(400, "invalid_read_session_id", "Read session id must be a UUID.");
  }

  const body = parseReadSessionEventBody(await readJson(request));
  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    with target_session as (
      select id, message_id
      from cryptoscreen.sealed_message_read_sessions
      where id = ${readSessionID}::uuid
        and expires_at > now()
      limit 1
    ),
    inserted_event as (
      insert into cryptoscreen.sealed_message_read_session_events (
      read_session_id,
      event_type,
      occurred_at
    )
    select
      id,
      ${body.type},
      ${body.timestamp}::timestamptz
      from target_session
      returning id
    ),
    updated_audit as (
      update cryptoscreen.sealed_message_delivery_audit
      set
        screenshot_detected_at = coalesce(screenshot_detected_at, ${body.timestamp}::timestamptz, now()),
        interaction_status_opted_in_at = coalesce(interaction_status_opted_in_at, ${body.timestamp}::timestamptz, now()),
        updated_at = now()
      where message_id in (select message_id from target_session)
      returning message_id
    )
    select id from inserted_event
  `;

  if (rows.length === 0) {
    throw new HttpError(410, "read_session_unavailable", "This read session is no longer available.");
  }

  return jsonResponse({ ok: true }, 202, {
    "Cache-Control": "no-store"
  });
}

async function recordMessageEvent(request: Request, env: Env, messageID: string): Promise<Response> {
  if (!UUID_RE.test(messageID)) {
    throw new HttpError(400, "invalid_message_id", "Message id must be a UUID.");
  }

  const body = parseReadSessionEventBody(await readJson(request));
  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    update cryptoscreen.sealed_message_delivery_audit
    set
      screenshot_detected_at = coalesce(screenshot_detected_at, ${body.timestamp}::timestamptz, now()),
      interaction_status_opted_in_at = coalesce(interaction_status_opted_in_at, ${body.timestamp}::timestamptz, now()),
      updated_at = now()
    where message_id = ${messageID}::uuid
      and text_consumed_at is not null
    returning message_id
  `;

  if (rows.length === 0) {
    throw new HttpError(410, "message_event_unavailable", "This message read session is no longer available.");
  }

  return jsonResponse({ ok: true }, 202, {
    "Cache-Control": "no-store"
  });
}

async function expireMessage(request: Request, env: Env, messageID: string): Promise<Response> {
  if (!UUID_RE.test(messageID)) {
    throw new HttpError(400, "invalid_message_id", "Message id must be a UUID.");
  }

  const body = parseExpireBody(await readJson(request));
  const revokeVerifierHex = bytesToHex(await pepperPinProof(base64UrlToBytes(body.revokeProof, "revokeProof", 32, 32), env));
  const sql = neon(env.DATABASE_URL);
  const stateRows = await sql`
    select
      retained,
      expires_at <= now() as is_expired,
      revoke_verifier is null as missing_revoke_verifier,
      revoke_verifier = decode(${revokeVerifierHex}, 'hex') as proof_matches
    from cryptoscreen.sealed_messages
    where id = ${messageID}::uuid
    limit 1
  `;

  if (stateRows.length === 0) {
    return await messageStatus(env, messageID);
  }

  const state = expectDatabaseRecord(stateRows[0]);
  const retained = expectDatabaseBoolean(state.retained, "retained");
  const isExpired = expectDatabaseBoolean(state.is_expired, "is_expired");
  const missingRevokeVerifier = expectDatabaseBoolean(state.missing_revoke_verifier, "missing_revoke_verifier");
  const proofMatches = expectDatabaseBoolean(state.proof_matches, "proof_matches");

  if (retained) {
    throw new HttpError(409, "retained_message_not_revocable", "Service-owned retained messages cannot be expired this way.");
  }

  if (isExpired) {
    return await messageStatus(env, messageID);
  }

  if (missingRevokeVerifier) {
    throw new HttpError(409, "message_not_revocable", "This message was created before link expiration was supported.");
  }

  if (!proofMatches) {
    throw new HttpError(403, "invalid_revoke_proof", "This sender cannot expire the message.");
  }

  const objectRows = await sql`
    select object_key
    from cryptoscreen.sealed_message_attachments
    where message_id = ${messageID}::uuid
  `;
  const bucket = (env as Env & { ATTACHMENTS?: R2Bucket }).ATTACHMENTS;
  if (bucket) {
    await Promise.all(
      objectRows
        .map((row) => expectDatabaseString(expectDatabaseRecord(row).object_key, "object_key"))
        .map((objectKey) => bucket.delete(objectKey))
    );
  }

  await sql`
    insert into cryptoscreen.sealed_message_delivery_audit (message_id, expired_at, created_at, updated_at)
    values (${messageID}::uuid, now(), now(), now())
    on conflict (message_id) do update
    set
      expired_at = coalesce(cryptoscreen.sealed_message_delivery_audit.expired_at, now()),
      updated_at = now()
  `;

  await sql`
    delete from cryptoscreen.sealed_messages
    where id = ${messageID}::uuid
      and not retained
      and revoke_verifier = decode(${revokeVerifierHex}, 'hex')
  `;

  return await messageStatus(env, messageID);
}

async function messageStatus(env: Env, messageID: string): Promise<Response> {
  if (!UUID_RE.test(messageID)) {
    throw new HttpError(400, "invalid_message_id", "Message id must be a UUID.");
  }

  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    with expiring_message as (
      select id
      from cryptoscreen.sealed_messages
      where id = ${messageID}::uuid
        and not retained
        and expires_at <= now()
    ),
    marked_expired as (
      update cryptoscreen.sealed_message_delivery_audit
      set
        expired_at = coalesce(expired_at, now()),
        updated_at = now()
      where message_id in (select id from expiring_message)
      returning message_id
    ),
    deleted_expired as (
      delete from cryptoscreen.sealed_messages
      where id = ${messageID}::uuid
        and not retained
        and expires_at <= now()
      returning id
    ),
    active_message as (
      select id
      from cryptoscreen.sealed_messages
      where id = ${messageID}::uuid
      limit 1
    )
    select
      case
        when exists (select 1 from active_message) then 'active'
        when audit.destroyed_at is not null then 'destroyed'
        when audit.expired_at is not null or exists (select 1 from deleted_expired) then 'expired'
        else 'consumed'
      end as status,
      coalesce(audit.interaction_status_opted_in_at is not null, false) as interaction_status_shared,
      case
        when coalesce(audit.interaction_status_opted_in_at is not null, false) then coalesce(audit.text_consumed_at is not null, false)
        else false
      end as text_consumed,
      case
        when coalesce(audit.interaction_status_opted_in_at is not null, false) then coalesce(audit.has_image_attachment, false)
        else false
      end as image_attachment_attached,
      case
        when coalesce(audit.interaction_status_opted_in_at is not null, false) then coalesce(audit.image_consumed_at is not null, false)
        else false
      end as image_attachment_consumed,
      case
        when coalesce(audit.interaction_status_opted_in_at is not null, false) then coalesce(audit.screenshot_detected_at is not null, false)
        else false
      end as screenshot_detected
    from (select 1) singleton
    left join cryptoscreen.sealed_message_delivery_audit audit
      on audit.message_id = ${messageID}::uuid
  `;

  return jsonResponse(parseMessageStatusRow(rows[0]), 200, {
    "Cache-Control": "no-store"
  });
}

async function deleteExpiredMessages(env: Env): Promise<void> {
  const sql = neon(env.DATABASE_URL);
  const bucket = (env as Env & { ATTACHMENTS?: R2Bucket }).ATTACHMENTS;
  if (bucket) {
    const rows = await sql`
      select object_key
      from cryptoscreen.sealed_message_attachments
      where expires_at <= now()
      union
      select object_key
      from cryptoscreen.sealed_message_read_sessions
      where expires_at <= now()
    `;

    await Promise.all(
      rows
        .map((row) => expectDatabaseString(expectDatabaseRecord(row).object_key, "object_key"))
        .map((objectKey) => bucket.delete(objectKey))
    );
  }

  await sql`select cryptoscreen.delete_expired_sealed_messages()`;
  await sql`
    delete from cryptoscreen.sealed_message_delivery_audit
    where updated_at <= now() - interval '30 days'
  `;
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
    revokeProof: body.revokeProof === undefined ? undefined : expectString(body.revokeProof, "revokeProof"),
    ttlSeconds
  };
}

function parseConsumeBody(value: unknown): ConsumeMessageBody {
  const body = expectRecord(value);

  return {
    pinProof: expectString(body.pinProof, "pinProof"),
    clientOptIn: body.clientOptIn === true
  };
}

function parseExpireBody(value: unknown): ExpireMessageBody {
  const body = expectRecord(value);

  return {
    revokeProof: expectString(body.revokeProof, "revokeProof")
  };
}

function parseFeedbackBody(value: unknown): FeedbackBody {
  const body = expectRecord(value);
  const rating = expectInteger(body.rating, "rating");
  if (rating < 1 || rating > 5) {
    throw new HttpError(400, "invalid_rating", "rating must be between 1 and 5.");
  }

  const message = expectString(body.message, "message").trim();
  if (message.length === 0) {
    throw new HttpError(400, "invalid_feedback", "message must not be empty.");
  }
  if (message.length > MAX_FEEDBACK_MESSAGE_CHARS) {
    throw new HttpError(400, "feedback_too_long", `message must be ${MAX_FEEDBACK_MESSAGE_CHARS} characters or fewer.`);
  }

  const timestamp = expectString(body.timestamp, "timestamp").trim();
  if (timestamp.length > MAX_FEEDBACK_TIMESTAMP_CHARS || Number.isNaN(Date.parse(timestamp))) {
    throw new HttpError(400, "invalid_timestamp", "timestamp must be a valid ISO-8601 date string.");
  }

  return {
    rating,
    message,
    appVersion: expectOptionalString(body.appVersion, "appVersion", MAX_FEEDBACK_METADATA_CHARS),
    buildNumber: expectOptionalString(body.buildNumber, "buildNumber", MAX_FEEDBACK_METADATA_CHARS),
    platform: expectOptionalString(body.platform, "platform", MAX_FEEDBACK_METADATA_CHARS),
    device: expectOptionalString(body.device, "device", MAX_FEEDBACK_METADATA_CHARS),
    timestamp
  };
}

function parseReadSessionEventBody(value: unknown): ReadSessionEventBody {
  const body = expectRecord(value);
  const type = expectString(body.type, "type");
  if (!isReadSessionEventType(type)) {
    throw new HttpError(400, "invalid_event_type", "Only screenshot events are supported.");
  }

  if (body.clientOptIn !== true) {
    throw new HttpError(403, "event_reporting_opt_in_required", "Interaction status reporting requires explicit client opt-in.");
  }

  const timestamp = expectString(body.timestamp, "timestamp").trim();
  if (timestamp.length > MAX_FEEDBACK_TIMESTAMP_CHARS || Number.isNaN(Date.parse(timestamp))) {
    throw new HttpError(400, "invalid_timestamp", "timestamp must be a valid ISO-8601 date string.");
  }

  return {
    type,
    timestamp,
    clientOptIn: true
  };
}

function parseAttachmentContentType(value: string | null): AttachmentContentType {
  const contentType = value?.trim().toLowerCase();
  if (!contentType || !isAttachmentContentType(contentType)) {
    throw new HttpError(400, "invalid_attachment_content_type", "Only JPEG, PNG, HEIC, and HEIF images are supported.");
  }

  return contentType;
}

function expectHeader(value: string | null, field: string): string {
  const trimmed = value?.trim();
  if (!trimmed) {
    throw new HttpError(400, "missing_header", `${field} is required.`);
  }

  return trimmed;
}

async function readAttachmentBytes(request: Request): Promise<Uint8Array> {
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_ATTACHMENT_BYTES) {
    throw new HttpError(413, "attachment_too_large", "The encrypted attachment is too large.");
  }

  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength === 0) {
    throw new HttpError(400, "empty_attachment", "The encrypted attachment must not be empty.");
  }
  if (bytes.byteLength > MAX_ATTACHMENT_BYTES) {
    throw new HttpError(413, "attachment_too_large", "The encrypted attachment is too large.");
  }

  return bytes;
}

function attachmentBucket(env: Env): R2Bucket {
  const bucket = (env as Env & { ATTACHMENTS?: R2Bucket }).ATTACHMENTS;
  if (!bucket) {
    throw new HttpError(500, "attachments_not_configured", "Encrypted attachment storage is not configured.");
  }

  return bucket;
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

function expectInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new HttpError(400, "invalid_field", `${field} must be an integer.`);
  }

  return value;
}

function expectOptionalString(value: unknown, field: string, maxLength: number): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }

  if (typeof value !== "string") {
    throw new HttpError(400, "invalid_field", `${field} must be a string.`);
  }

  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  if (trimmed.length > maxLength) {
    throw new HttpError(400, "invalid_field", `${field} is too long.`);
  }

  return trimmed;
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

async function sendFeedbackEmail(feedback: FeedbackBody, env: Env): Promise<void> {
  const recipient = env.FEEDBACK_EMAIL || env.SUPPORT_EMAIL;
  const from = env.FEEDBACK_FROM_EMAIL;
  if (!recipient || !from) {
    throw new HttpError(500, "feedback_not_configured", "Private feedback email is not configured.");
  }

  await env.FEEDBACK_EMAIL_SENDER.send({
    from,
    to: recipient,
    subject: `cryptoscreen onboarding feedback (${feedback.rating}/5)`,
    text: feedbackEmailText(feedback)
  });
}

function feedbackEmailText(feedback: FeedbackBody): string {
  return [
    "cryptoscreen onboarding feedback",
    "",
    `Rating: ${feedback.rating}/5`,
    `Timestamp: ${feedback.timestamp}`,
    `App version: ${feedback.appVersion ?? "unknown"}`,
    `Build number: ${feedback.buildNumber ?? "unknown"}`,
    `Platform: ${feedback.platform ?? "unknown"}`,
    `Device: ${feedback.device ?? "unknown"}`,
    "",
    "Feedback:",
    feedback.message
  ].join("\n");
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

function parseAttachmentMetadataRow(value: unknown): AttachmentMetadataRow {
  const row = expectDatabaseRecord(value);

  return {
    id: expectDatabaseString(row.id, "id"),
    expires_at: expectDatabaseString(row.expires_at, "expires_at")
  };
}

function parseMessageAttachmentStateRow(value: unknown): MessageAttachmentStateRow {
  const row = expectDatabaseRecord(value);
  const hasAttachment = row.has_attachment;
  if (typeof hasAttachment !== "boolean") {
    throw new HttpError(500, "invalid_database_result", "Attachment state returned an invalid value.");
  }

  return {
    expires_at: expectNullableDatabaseString(row.expires_at, "expires_at"),
    has_attachment: hasAttachment
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
    retained: expectNullableDatabaseBoolean(row.retained, "retained"),
    ciphertext: expectNullableDatabaseString(row.ciphertext, "ciphertext"),
    nonce: expectNullableDatabaseString(row.nonce, "nonce"),
    tag: expectNullableDatabaseString(row.tag, "tag"),
    salt: expectNullableDatabaseString(row.salt, "salt"),
    attachment_id: expectNullableDatabaseString(row.attachment_id, "attachment_id"),
    attachment_object_key: expectNullableDatabaseString(row.attachment_object_key, "attachment_object_key"),
    attachment_type: parseNullableAttachmentType(row.attachment_type),
    attachment_content_type: parseNullableAttachmentContentType(row.attachment_content_type),
    attachment_ciphertext_bytes: expectNullableDatabaseNumber(row.attachment_ciphertext_bytes, "attachment_ciphertext_bytes"),
    attachment_encrypted_file_key: expectNullableDatabaseString(row.attachment_encrypted_file_key, "attachment_encrypted_file_key")
  };
}

function parseConsumeRowWithoutAttachment(value: unknown): ConsumeMessageRow {
  const row = expectDatabaseRecord(value);
  const status = expectDatabaseString(row.status, "status");

  if (!isConsumeStatus(status)) {
    throw new HttpError(500, "invalid_database_result", "Consume returned an invalid status.");
  }

  return {
    status,
    remaining_attempts: expectNullableDatabaseNumber(row.remaining_attempts, "remaining_attempts"),
    retained: expectNullableDatabaseBoolean(row.retained, "retained") ?? false,
    ciphertext: expectNullableDatabaseString(row.ciphertext, "ciphertext"),
    nonce: expectNullableDatabaseString(row.nonce, "nonce"),
    tag: expectNullableDatabaseString(row.tag, "tag"),
    salt: expectNullableDatabaseString(row.salt, "salt"),
    attachment_id: null,
    attachment_object_key: null,
    attachment_type: null,
    attachment_content_type: null,
    attachment_ciphertext_bytes: null,
    attachment_encrypted_file_key: null
  };
}

function parseReadSessionRow(value: unknown): ReadSessionRow {
  const row = expectDatabaseRecord(value);
  const contentType = expectDatabaseString(row.content_type, "content_type");
  if (!isAttachmentContentType(contentType)) {
    throw new HttpError(500, "invalid_database_result", "Read session returned an invalid content type.");
  }

  return {
    message_id: expectDatabaseString(row.message_id, "message_id"),
    object_key: expectDatabaseString(row.object_key, "object_key"),
    content_type: contentType,
    ciphertext_bytes: expectDatabaseNumber(row.ciphertext_bytes, "ciphertext_bytes")
  };
}

function parseMessageStatusRow(value: unknown): MessageStatusRow {
  const row = expectDatabaseRecord(value);
  const status = expectDatabaseString(row.status, "status");

  if (!messageStatuses.includes(status as MessageStatusRow["status"])) {
    throw new HttpError(500, "invalid_database_result", "Message status returned an invalid value.");
  }

  return {
    status: status as MessageStatusRow["status"],
    interactionStatusShared: expectDatabaseBoolean(row.interaction_status_shared, "interaction_status_shared"),
    textConsumed: expectDatabaseBoolean(row.text_consumed, "text_consumed"),
    imageAttachmentAttached: expectDatabaseBoolean(row.image_attachment_attached, "image_attachment_attached"),
    imageAttachmentConsumed: expectDatabaseBoolean(row.image_attachment_consumed, "image_attachment_consumed"),
    screenshotDetected: expectDatabaseBoolean(row.screenshot_detected, "screenshot_detected")
  };
}

function parseMessageStatsRow(value: unknown): MessageStats {
  const row = expectDatabaseRecord(value);

  return {
    sharedMessages: expectDatabaseCount(row.shared_messages, "shared_messages"),
    imageAttachmentsShared: expectDatabaseCount(row.image_attachments_shared, "image_attachments_shared"),
    updatedAt: expectNullableDatabaseString(row.updated_at, "updated_at")
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

function expectDatabaseCount(value: unknown, field: string): number {
  const count = typeof value === "number"
    ? value
    : typeof value === "string" && /^\d+$/.test(value)
      ? Number(value)
      : Number.NaN;

  if (!Number.isSafeInteger(count) || count < 0) {
    throw new HttpError(500, "invalid_database_result", `The database field ${field} was invalid.`);
  }

  return count;
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

function expectDatabaseBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw new HttpError(500, "invalid_database_result", `The database field ${field} was invalid.`);
  }

  return value;
}

function expectNullableDatabaseBoolean(value: unknown, field: string): boolean | null {
  if (value === null) {
    return null;
  }

  if (typeof value !== "boolean") {
    throw new HttpError(500, "invalid_database_result", `The database field ${field} was invalid.`);
  }

  return value;
}

function isConsumeStatus(value: string): value is ConsumeMessageRow["status"] {
  return consumeStatuses.includes(value as ConsumeMessageRow["status"]);
}

function parseNullableAttachmentType(value: unknown): "image" | null {
  if (value === null) {
    return null;
  }

  const attachmentType = expectDatabaseString(value, "attachment_type");
  if (attachmentType !== "image") {
    throw new HttpError(500, "invalid_database_result", "Consume returned an invalid attachment type.");
  }

  return attachmentType;
}

function parseNullableAttachmentContentType(value: unknown): AttachmentContentType | null {
  if (value === null) {
    return null;
  }

  const contentType = expectDatabaseString(value, "attachment_content_type");
  if (!isAttachmentContentType(contentType)) {
    throw new HttpError(500, "invalid_database_result", "Consume returned an invalid attachment content type.");
  }

  return contentType;
}

function isAttachmentContentType(value: string): value is AttachmentContentType {
  return attachmentContentTypes.includes(value as AttachmentContentType);
}

function isReadSessionEventType(value: string): value is ReadSessionEventBody["type"] {
  return readSessionEventTypes.includes(value as ReadSessionEventBody["type"]);
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

function htmlResponse(body: string, status = 200, cacheControl = "public, max-age=300"): Response {
  return new Response(body, {
    status,
    headers: {
      ...securityHeaders,
      "Cache-Control": cacheControl,
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

async function homePage(env: Env): Promise<string> {
  const links = siteLinks(env);
  const stats = await safeMessageStats(env);
  const sharedMessages = stats ? formatStatNumber(stats.sharedMessages) : "...";
  const imageAttachmentsShared = stats ? formatStatNumber(stats.imageAttachmentsShared) : "...";

  return pageShell(
    "cryptoscreen",
    env,
    `
      <section class="hero">
        <div class="hero-illustration">
          <img src="/assets/hands-on-screen.svg" width="404" height="396" alt="Hand placement guide illustration from cryptoscreen onboarding">
        </div>
        <div class="hero-copy">
          <p class="eyebrow">One-time private reading</p>
          <h1>cryptoscreen</h1>
          <p class="lede">
            Sealed messages for iPhone. The sender encrypts locally, shares a link and PIN, and the recipient gets one controlled read before the row disappears.
          </p>
          <div class="stat-strip" aria-label="cryptoscreen stats">
            <div class="stat-item">
              <span class="stat-value" data-shared-messages aria-live="polite">${sharedMessages}</span>
              <span class="stat-label">messages shared</span>
            </div>
            <div class="stat-item">
              <span class="stat-value" data-image-attachments-shared aria-live="polite">${imageAttachmentsShared}</span>
              <span class="stat-label">images shared</span>
            </div>
            <div class="stat-item">
              <span class="stat-value">1</span>
              <span class="stat-label">read per link</span>
            </div>
            <div class="stat-item">
              <span class="stat-value">${LINK_RETENTION_DAYS}</span>
              <span class="stat-label">day maximum</span>
            </div>
          </div>
          <div class="actions">
            <a class="button primary" href="${escapeAttribute(links.appStoreUrl)}" rel="noreferrer">Download on the App Store</a>
            <a class="button" href="/support">Support</a>
            <a class="button ghost" href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
            <a class="button ghost" href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
          </div>
          <div class="sponsor-cta" aria-label="Sponsor the project">
            <iframe src="https://github.com/sponsors/DomenicoDD/button" title="Sponsor DomenicoDD" height="32" width="114" loading="lazy"></iframe>
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
          <p>A correct PIN consumes the server row. The third wrong PIN destroys it. Unused links expire after ${LINK_RETENTION_DAYS} days.</p>
          <p>If iOS reports a screenshot while a note is open, cryptoscreen immediately wipes the visible reader session. Screenshot detection is best-effort and cannot protect against external cameras or compromised devices.</p>
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
          <p>The reader reveals a narrow window, with capture redaction, screenshot-triggered destruction, and no selectable plaintext.</p>
        </article>
      </section>
      <section class="section apple-strip">
        <div>
          <p class="eyebrow">Apple review links</p>
          <h2>Required public endpoints are hosted here.</h2>
        </div>
        <nav class="link-list" aria-label="Apple review">
          <a href="/privacy">Privacy Policy</a>
          <a href="/security">Security Resources</a>
          <a href="/support">Support</a>
          <a href="/.well-known/apple-app-site-association">Apple association</a>
          <a href="/m/example-message-id">Universal link page</a>
        </nav>
      </section>
    `,
    undefined,
    homeStatsScript()
  );
}

function messagePage(url: URL, env: Env): string {
  const messageID = escapeHtml(url.pathname.split("/").pop() ?? "");
  const messageUrl = messageUrlWithoutFragment(url, env);
  const links = siteLinks(env);

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
          The decryption secret belongs in the URL fragment after <code>#s=</code>. Browsers do not send that fragment to this server. If iOS reports a screenshot while the note is open, the app destroys the visible reader session.
        </p>
        <div class="actions">
          <a class="button primary" data-open-message href="${escapeAttribute(messageUrl)}">Open message</a>
          <a class="button" href="${escapeAttribute(links.appStoreUrl)}">Download on the App Store</a>
          <a class="button" href="/support">Support</a>
        </div>
        <p class="hint">
          On iPhone, this button uses the same universal link. If the app is installed, iOS opens the app. Otherwise, install cryptoscreen from the App Store.
        </p>
      </section>
    `,
    true
  );
}

function privacyPage(env: Env): string {
  return pageShell(
    "Privacy & Security Policy",
    env,
    `
      <section class="panel prose">
        <p class="eyebrow">Privacy & Security Policy</p>
        <h1>cryptoscreen Privacy & Security Policy</h1>
        <p>cryptoscreen is designed for one-time encrypted messages. The note is encrypted on the sender device before upload. The service is designed not to receive plaintext, raw image bytes, PINs, decryption keys, contact lists, or account profiles.</p>
        <h2>What the server cannot read</h2>
        <p>The server stores ciphertext and encrypted attachment bytes only. The decryption secret is kept in the URL fragment after <code>#s=</code>, which browsers do not send to the server in normal HTTP requests. The six-digit PIN is entered locally and is not stored by the service.</p>
        <h2>What the service stores to make messages work</h2>
        <p>The production API stores encrypted message bytes, nonce, tag, salt, expiry time, failed attempt count, and a server-peppered PIN verifier. When a sender attaches an image, the service stores encrypted image object bytes in private R2 storage plus encrypted attachment metadata in Neon. User message rows and attachment metadata are deleted after a successful read, after the third wrong PIN, or after expiry cleanup. Unused user links expire after ${LINK_RETENTION_DAYS} days.</p>
        <p>After a successful read with an image attachment, the app downloads the encrypted image bytes through a short-lived one-time read session. The R2 object is deleted after that one-time download. Expired attachment objects and read sessions are deleted by scheduled cleanup.</p>
        <h2>Status data and telemetry</h2>
        <p>cryptoscreen does not use ad SDKs, tracking SDKs, third-party analytics SDKs, or contact upload. There is no account profile.</p>
        <p>One-time links necessarily reveal some delivery state. If a link no longer opens, the sender or recipient can infer that the message was already opened, expired, destroyed after wrong PIN attempts, or manually expired by the sender. This is part of enforcing one-time reads and does not require telemetry opt-in.</p>
        <p>To support one-time deletion and the optional sent-message list, the service keeps minimal delivery-status metadata for a message id: whether the text was consumed, whether an encrypted image attachment existed, whether that image was consumed, whether the row expired or was destroyed, and whether a screenshot event was reported. This status metadata does not include plaintext, image plaintext, PINs, link secrets, sender identity, recipient identity, or contact data. Delivery-status metadata is deleted by scheduled cleanup after it has been inactive for about ${LINK_RETENTION_DAYS} days.</p>
        <p>Interaction status sharing is opt-in in the app's Privacy settings and works reciprocally. If it is off, the app does not send optional read or screenshot status and does not fetch or show detailed interaction status for messages you sent. If it is on, you can see detailed interaction status only when the reader also shared interaction status from their app. Screenshot reports contain only a generic screenshot event and timestamp for that message. Screenshot detection is best-effort: iOS reports normal screenshots after capture, modified clients can omit reporting, and external cameras cannot be detected.</p>
        <p>The service also keeps an aggregate count of how many sealed messages have been shared. That counter does not include message content, recipients, senders, or link secrets.</p>
        <p>If you send feedback from inside the app, the service processes the rating, feedback text, app version/build, platform/device information, and timestamp to deliver that support request to the maintainer.</p>
        <h2>App Store data</h2>
        <p>Apple separately processes App Store downloads, crash diagnostics, reviews, and any App Store support interactions under Apple's own terms. This is Apple platform infrastructure, not a cryptoscreen tracking SDK.</p>
        <h2>Operational data</h2>
        <p>Cloudflare, Neon, and Cloudflare R2 provide the infrastructure for the public site, API, database, and encrypted attachment storage. They may process standard infrastructure logs needed to operate, secure, and debug the service. cryptoscreen application logs must not intentionally include plaintext, PINs, proofs, full message links, or raw image data.</p>
        <h2>Limits</h2>
        <p>cryptoscreen cannot stop a recipient from photographing the screen with another device, using a compromised device, or saving content after it is legitimately displayed. The product promise is narrower: the service is designed not to be able to read your message content, and normal message rows are one-time by default.</p>
        <h2>Contact</h2>
        <p>For privacy requests, use the contact address on the support page.</p>
      </section>
    `
  );
}

function termsPage(env: Env): string {
  return pageShell(
    "Terms of Service",
    env,
    `
      <section class="panel prose">
        <p class="eyebrow">Terms of Service</p>
        <h1>cryptoscreen Terms of Service</h1>
        <p>cryptoscreen is a tool for one-time encrypted notes. Use it only for content you are allowed to share and only with people you trust.</p>
        <h2>Security model</h2>
        <p>The service is designed so message plaintext, raw image bytes, PINs, and decryption keys are not available to the server. The app cannot protect content after a recipient has legitimately viewed it, and it cannot prevent external cameras, compromised devices, or modified clients.</p>
        <h2>Availability and deletion</h2>
        <p>Normal user messages are intended to be available for one successful read, destroyed after the third wrong PIN attempt, manually expired by the sender, or expired after ${LINK_RETENTION_DAYS} days if unopened. Deleted or expired messages cannot be recovered by cryptoscreen. Because unavailable links stop opening, people with the link may be able to infer that one of those events happened.</p>
        <h2>Service changes</h2>
        <p>The service may change over time. Do not use cryptoscreen as the only copy of important information.</p>
        <h2>Privacy</h2>
        <p>The Privacy & Security Policy explains what data is stored, what is not stored, and which optional reports can be enabled in the app.</p>
      </section>
    `
  );
}

function securityPage(env: Env): string {
  const links = siteLinks(env);

  return pageShell(
    "Security Resources",
    env,
    `
      <section class="security-hero">
        <div>
          <p class="eyebrow">Security Resources</p>
          <h1>Security architecture for one-time iPhone notes.</h1>
          <p class="lede">
            cryptoscreen is built around local encryption, PIN-gated opening, short-lived server rows, and explicit limits. This page explains what is protected, what the server stores, and where the trust boundary ends.
          </p>
          <div class="actions">
            <a class="button primary" href="${escapeAttribute(links.appStoreUrl)}" rel="noreferrer">Download on the App Store</a>
            <a class="button" href="/privacy">Privacy Policy</a>
            <a class="button ghost" href="/support">Support</a>
          </div>
        </div>
        <nav class="toc" aria-label="Security page sections">
          <a href="#basics"><span>01</span> Security basics</a>
          <a href="#cryptography"><span>02</span> Cryptography</a>
          <a href="#storage"><span>03</span> Storage and deletion</a>
          <a href="#operations"><span>04</span> Operational security</a>
          <a href="#threat-model"><span>05</span> Threat model</a>
        </nav>
      </section>

      <section class="numbered-section" id="basics">
        <div>
          <span class="section-number">01</span>
          <p class="eyebrow">Security basics</p>
          <h2>The message is sealed before upload.</h2>
        </div>
        <div class="copy-stack">
          <p>The sender writes the note in the iPhone app. The app derives the content key locally from the link secret and six-digit PIN, encrypts the plaintext, and uploads only encrypted bytes plus the metadata needed to enforce expiry and PIN attempts.</p>
          <p>The URL fragment after <code>#s=</code> carries the link secret. Browsers do not send that fragment to the Worker in normal HTTP requests, so the server receives the message id but not the decryption secret.</p>
          <p>The PIN is not stored by cryptoscreen. The app sends a PIN proof so the Worker can decide whether to release the encrypted payload without learning the PIN or plaintext.</p>
        </div>
      </section>

      <section class="security-grid" id="cryptography" aria-label="Cryptography details">
        <article>
          <span>02A</span>
          <h3>AES-GCM message encryption</h3>
          <p>Message text is encrypted with Apple CryptoKit <code>AES.GCM</code>. The API stores ciphertext, nonce, tag, and salt separately.</p>
        </article>
        <article>
          <span>02B</span>
          <h3>HKDF-SHA256 key derivation</h3>
          <p>The content key is derived from a 32-byte link secret, the normalized six-digit PIN, and a 16-byte per-message salt using HKDF-SHA256.</p>
        </article>
        <article>
          <span>02C</span>
          <h3>PIN verifier separation</h3>
          <p>The online PIN proof uses a separate HKDF-SHA256 context and is stored by the Worker only after applying a server-side pepper.</p>
        </article>
        <article>
          <span>02D</span>
          <h3>Image attachment wrapping</h3>
          <p>Image attachments use a random 32-byte file key. The image is encrypted with that key, then the file key is encrypted with the message key.</p>
        </article>
      </section>

      <section class="numbered-section" id="storage">
        <div>
          <span class="section-number">03</span>
          <p class="eyebrow">Storage and deletion</p>
          <h2>The server stores enough to enforce one controlled read.</h2>
        </div>
        <div class="copy-stack">
          <p>Neon stores encrypted message bytes, nonce, tag, salt, expiry time, failed attempt count, and a server-peppered PIN verifier. Cloudflare R2 stores encrypted image object bytes when an image is attached.</p>
          <p>User message rows delete after one successful read, after the third wrong PIN attempt, when the sender expires the message, or after ${LINK_RETENTION_DAYS} days if unopened. Encrypted attachment objects are removed after their one-time download or scheduled cleanup.</p>
          <p>cryptoscreen keeps minimal delivery status so the app can show whether a sent message was consumed, expired, destroyed, or reported a screenshot event when reciprocal interaction status is enabled. That status does not include plaintext, image plaintext, PINs, link secrets, sender contacts, or recipient contacts.</p>
        </div>
      </section>

      <section class="numbered-section" id="operations">
        <div>
          <span class="section-number">04</span>
          <p class="eyebrow">Operational security</p>
          <h2>The public site and API run behind strict browser and edge controls.</h2>
        </div>
        <div class="copy-stack">
          <ul class="security-list">
            <li>No ad SDKs, tracking SDKs, third-party analytics SDKs, accounts, or contact upload.</li>
            <li>Security headers include a restrictive Content Security Policy, no-referrer policy, HSTS, and frame blocking.</li>
            <li>The Cloudflare Worker validates request sizes, payload formats, attachment types, UUIDs, TTL bounds, and supported image content types.</li>
            <li>Application logs must not intentionally include plaintext, PINs, PIN proofs, full message links, or raw image data.</li>
          </ul>
        </div>
      </section>

      <section class="security-grid" id="threat-model" aria-label="Threat model and limitations">
        <article>
          <span>05A</span>
          <h3>Designed to protect</h3>
          <p>Message plaintext, raw image bytes, link secrets, PIN values, and one-time read behavior from routine server-side access or database-only compromise.</p>
        </article>
        <article>
          <span>05B</span>
          <h3>Required assumptions</h3>
          <p>The sender and recipient devices are trusted while encrypting or reading, iOS CryptoKit behaves correctly, and the delivered app build has not been maliciously modified.</p>
        </article>
        <article>
          <span>05C</span>
          <h3>Best-effort protections</h3>
          <p>Screenshot and screen recording responses reduce accidental exposure. iOS reports screenshots after capture, and external cameras cannot be detected.</p>
        </article>
        <article>
          <span>05D</span>
          <h3>Not covered</h3>
          <p>Compromised devices, malicious recipients, external cameras, phishing, social engineering, copied content after display, or link/PIN sharing with the wrong person.</p>
        </article>
      </section>

      <section class="security-callout">
        <div>
          <p class="eyebrow">Technical integrity</p>
          <h2>Security claims should stay measurable.</h2>
        </div>
        <p>cryptoscreen does not promise magic disappearing text. It promises a narrower system: encrypt locally, avoid server plaintext, release encrypted payloads only after a correct PIN proof, consume normal links once, and be clear about the limits.</p>
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
        <p>For help with App Store installs, message links, or deletion behavior, contact <a href="mailto:${escapeAttribute(links.supportEmail)}">${escapeHtml(links.supportEmail)}</a>.</p>
        <h2>Current behavior</h2>
        <p>User messages delete after one successful read, after the third wrong PIN, or after ${LINK_RETENTION_DAYS} days if never opened. Encrypted image attachment objects delete after their one-time attachment download or during scheduled expiry cleanup. Service-owned review/demo rows may be retained so Apple can repeatedly verify App Clip invocation.</p>
        <h2>Project links</h2>
        <p>
          Follow development on <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a> or contact the maintainer on <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>.
        </p>
        <h2>Safety note</h2>
        <p>Screenshot and screen recording protections are best-effort iOS protections. They reduce accidental exposure but cannot guarantee protection against external cameras or compromised devices. Interaction status sharing, including optional screenshot reports to the sender, is opt-in in the app's Privacy settings and works reciprocally.</p>
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

function pageShell(title: string, env: Env, content: string, preserveFragment = false, bodyScript = ""): string {
  const escapedTitle = escapeHtml(title);
  const description = "cryptoscreen seals one-time encrypted messages for private reading on iPhone.";
  const links = siteLinks(env);

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    ${preserveFragment ? fragmentForwardingScript() : ""}
    <meta name="description" content="${escapeAttribute(description)}">
    <meta name="theme-color" content="#08100b">
    <link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
    <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
    <link rel="manifest" href="/site.webmanifest">
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
        max-width: 680px;
        padding: clamp(28px, 7vw, 78px);
        position: relative;
        z-index: 1;
      }
      .hero-illustration {
        position: absolute;
        right: clamp(22px, 7vw, 92px);
        top: clamp(40px, 9vw, 118px);
        width: min(36vw, 430px);
        z-index: 0;
        filter: drop-shadow(0 0 22px oklch(79% 0.21 152 / 0.28));
        opacity: 0.94;
        pointer-events: none;
      }
      .hero-illustration img {
        display: block;
        height: auto;
        width: 100%;
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
      .stat-strip {
        display: grid;
        grid-template-columns: repeat(4, minmax(116px, max-content));
        gap: 14px 26px;
        margin-top: 28px;
      }
      .stat-item {
        border-left: 1px solid var(--line-strong);
        min-width: 116px;
        padding-left: 14px;
      }
      .stat-value {
        color: var(--ink);
        display: block;
        font-size: clamp(26px, 5vw, 40px);
        font-variant-numeric: tabular-nums;
        font-weight: 800;
        line-height: 1;
        min-height: 1em;
      }
      .stat-label {
        color: var(--muted);
        display: block;
        font-size: 12px;
        font-weight: 800;
        line-height: 1.35;
        margin-top: 8px;
        text-transform: uppercase;
      }
      .actions {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        margin-top: 28px;
      }
      .sponsor-cta {
        display: flex;
        margin-top: 14px;
      }
      .sponsor-cta iframe {
        border: 0;
        border-radius: 6px;
        display: block;
        height: 32px;
        width: 114px;
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
      .security-hero {
        border: 1px solid var(--line);
        border-radius: 8px;
        background:
          linear-gradient(135deg, oklch(79% 0.21 152 / 0.08), transparent 42%),
          var(--panel);
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(260px, 360px);
        gap: clamp(28px, 7vw, 78px);
        padding: clamp(24px, 6vw, 54px);
      }
      .security-hero h1 {
        font-size: clamp(40px, 8vw, 78px);
        max-width: 780px;
      }
      .toc {
        align-content: start;
        display: grid;
        gap: 10px;
      }
      .toc a {
        border: 1px solid var(--line);
        border-radius: 8px;
        color: var(--soft-ink);
        display: grid;
        gap: 6px;
        padding: 13px 14px;
        text-decoration: none;
      }
      .toc a:hover {
        border-color: var(--line-strong);
        color: var(--ink);
      }
      .toc span, .section-number {
        color: var(--accent);
        font-size: 12px;
        font-weight: 800;
      }
      .numbered-section {
        border-top: 1px solid var(--line);
        display: grid;
        grid-template-columns: minmax(0, 0.8fr) minmax(0, 1fr);
        gap: clamp(28px, 8vw, 96px);
        padding: clamp(42px, 9vw, 96px) 0;
      }
      .section-number {
        display: block;
        margin-bottom: 18px;
      }
      .security-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 12px;
        padding-bottom: clamp(42px, 9vw, 96px);
      }
      .security-grid article {
        min-height: 260px;
      }
      .security-list {
        color: var(--muted);
        display: grid;
        gap: 12px;
        line-height: 1.6;
        margin: 0;
        padding-left: 18px;
      }
      .security-list li::marker {
        color: var(--accent);
      }
      .security-callout {
        border: 1px solid oklch(79% 0.21 152 / 0.28);
        border-radius: 8px;
        background: oklch(79% 0.21 152 / 0.06);
        display: grid;
        grid-template-columns: minmax(0, 0.9fr) minmax(0, 1fr);
        gap: 28px;
        padding: clamp(22px, 5vw, 34px);
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
      .hint {
        color: var(--quiet);
        font-size: 13px;
        line-height: 1.5;
        margin-top: 14px;
      }
      .browser-warning {
        border: 1px solid oklch(78% 0.15 77 / 0.38);
        border-radius: 8px;
        background: oklch(78% 0.15 77 / 0.1);
        color: var(--warn);
        font-size: 13px;
        line-height: 1.5;
        margin-top: 14px;
        padding: 12px 13px;
      }
      .browser-warning[hidden] {
        display: none;
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
        .stat-strip {
          gap: 12px;
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
        .stat-item {
          min-width: 0;
          padding-left: 10px;
        }
        .stat-value { font-size: 24px; }
        .stat-label { font-size: 10px; }
        .actions { align-items: stretch; flex-direction: column; }
        .button { width: 100%; }
        .sponsor-cta { justify-content: center; }
        .hero-illustration {
          opacity: 0.26;
          right: -84px;
          top: 76px;
          width: 320px;
        }
        .split, .steps, .apple-strip, .security-hero, .numbered-section, .security-grid, .security-callout { grid-template-columns: 1fr; }
        .section { padding: 42px 0; }
        .security-grid { padding-bottom: 42px; }
        .security-grid article { min-height: 0; }
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <header>
        <a class="brand" href="/">cryptoscreen</a>
        <nav aria-label="Main">
          <a href="/privacy">Privacy</a>
          <a href="/security">Security</a>
          <a href="/terms">Terms</a>
          <a href="/support">Support</a>
          <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
          <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
          <a href="/.well-known/apple-app-site-association">AASA</a>
        </nav>
      </header>
      <main>${content}</main>
      <footer>
        <span>cryptoscreen.app, one-time encrypted messages</span>
        <span>
          <a href="/privacy">Privacy</a>
          &nbsp;/&nbsp;
          <a href="/security">Security</a>
          &nbsp;/&nbsp;
          <a href="/terms">Terms</a>
          &nbsp;/&nbsp;
          <a href="/support">Support</a>
          &nbsp;/&nbsp;
          <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
          &nbsp;/&nbsp;
          <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
        </span>
      </footer>
    </div>
    ${bodyScript}
  </body>
</html>`;
}

function formatStatNumber(value: number): string {
  return new Intl.NumberFormat("en-US").format(value);
}

function messageUrlWithoutFragment(url: URL, env: Env): string {
  const baseUrl = siteBaseUrl(env);
  return `${baseUrl.origin}${url.pathname}${url.search}`;
}

function siteBaseUrl(env: Env): URL {
  const vars = env as unknown as Record<string, string | undefined>;

  try {
    const candidate = new URL(vars.APP_BASE_URL ?? "https://cryptoscreen.app");
    if (candidate.protocol === "https:") {
      return candidate;
    }
  } catch {
    // Fall through to the production domain.
  }

  return new URL("https://cryptoscreen.app");
}

function homeStatsScript(): string {
  return `<script>
(() => {
  const sharedMessagesValue = document.querySelector("[data-shared-messages]");
  const imageAttachmentsSharedValue = document.querySelector("[data-image-attachments-shared]");
  if (!sharedMessagesValue && !imageAttachmentsSharedValue) return;

  const format = (raw) => {
    const count = Number(raw);
    if (!Number.isFinite(count) || count < 0) return null;
    return new Intl.NumberFormat("en-US").format(count);
  };

  const refresh = async () => {
    try {
      const response = await fetch("/api/stats", {
        cache: "no-store",
        headers: { Accept: "application/json" }
      });
      if (!response.ok) return;
      const data = await response.json();
      const formattedSharedMessages = format(data.sharedMessages);
      if (formattedSharedMessages && sharedMessagesValue) {
        sharedMessagesValue.textContent = formattedSharedMessages;
      }
      const formattedImageAttachmentsShared = format(data.imageAttachmentsShared);
      if (formattedImageAttachmentsShared && imageAttachmentsSharedValue) {
        imageAttachmentsSharedValue.textContent = formattedImageAttachmentsShared;
      }
    } catch {
      // Leave the server-rendered count in place.
    }
  };

  window.setInterval(refresh, 30000);
  window.addEventListener("focus", refresh);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refresh();
  });
  refresh();
})();
</script>`;
}

function fragmentForwardingScript(): string {
  return `<script>
(() => {
  window.addEventListener("DOMContentLoaded", () => {
    const openMessage = document.querySelector("[data-open-message]");
    if (openMessage) openMessage.href = window.location.href;
  });
})();
</script>`;
}

function siteLinks(env: Env): {
  githubUrl: string;
  supportEmail: string;
  appStoreUrl: string;
  xUrl: string;
} {
  const vars = env as unknown as Record<string, string | undefined>;

  return {
    githubUrl: externalUrl(vars.GITHUB_REPOSITORY_URL ?? "https://github.com/DomenicoDD/cryptoscreen"),
    supportEmail: emailAddress(vars.SUPPORT_EMAIL ?? "domenico@cryptoscreen.app"),
    appStoreUrl: externalUrl(vars.APP_STORE_URL ?? "https://apps.apple.com/us/app/cryptoscreen/id6779173642"),
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
