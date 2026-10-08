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
const readPolicies = ["app_only", "web_allowed"] as const;
const readerClients = ["ios_app", "web"] as const;
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
  readPolicy: ReadPolicy;
  ttlSeconds?: number;
};

type ConsumeMessageBody = {
  pinProof: string;
  clientOptIn: boolean;
  readerClient?: ReaderClient;
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
  readPolicy: ReadPolicy | null;
  interactionStatusShared: boolean;
  textConsumed: boolean;
  imageAttachmentAttached: boolean;
  imageAttachmentConsumed: boolean;
  screenshotDetected: boolean;
};

type AttachmentContentType = (typeof attachmentContentTypes)[number];
type ReadPolicy = (typeof readPolicies)[number];
type ReaderClient = (typeof readerClients)[number];

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
let readPolicySchemaReady: Promise<void> | null = null;
let feedbackSchemaReady: Promise<void> | null = null;

const securityHeaders = {
  "Content-Security-Policy":
    "default-src 'none'; img-src 'self' data: blob:; font-src 'self'; style-src 'unsafe-inline'; script-src 'sha256-HrYFR5j+vBEKTDeLEB2Vy6i4YI+pbde+obDT+swl/kQ=' 'sha256-oliIv0zqQdHHMPWskJbWG5lm6PIJ+qkHWklpPiGaIRg=' 'sha256-+RY4XDwl+J7KAzZ6EeJi2DKTAdxsEbkbt48HhH0RIrY=' 'sha256-Vd8aqtexkb3ZJJd7td5IdWDQ9b95BAdzVi96KuybVKA=' 'sha256-tQVzJNpePIk/KfH+OJPj9OZdcrkPqQ57VLL0UygK5Mw=' 'sha256-PZlfPCbjh4Ng7Dq6+j7TXA9dt7rF8H68o7CkNIctWpk=' 'sha256-mMZH4jcxBAKplISWgqvx+d14O9s6Eyfbl9wshC2zK+s=' 'sha256-4rSsmLijBV/jBt6u6o5OESRnoIjTPvybMKhNWS7OTPk=' 'sha256-j1sQnEbvRRTybrWkvQ1q5ZjJDzzAU1qNUVlsPyNwn+0=' 'sha256-TQfsZ0n4LVq4tZ9lksR1YHmLtsBlagJ7hYmgK82PjFg=' 'sha256-TIJ9ywLbyIhMghxqK9jCdIWezEHrBRbrsaYHoUherQY='; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
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

      if (url.pathname === "/transparency") {
        return htmlResponse(transparencyPage(env));
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

async function ensureReadPolicySchema(env: Env): Promise<void> {
  if (!readPolicySchemaReady) {
    const sql = neon(env.DATABASE_URL);
    readPolicySchemaReady = applyReadPolicySchema(sql).catch((error) => {
      readPolicySchemaReady = null;
      throw error;
    });
  }

  await readPolicySchemaReady;
}

async function applyReadPolicySchema(sql: SqlClient): Promise<void> {
  await sql`
    do $$
    begin
      create type cryptoscreen.sealed_message_read_policy as enum (
        'app_only',
        'web_allowed'
      );
    exception
      when duplicate_object then null;
    end;
    $$
  `;

  await sql`
    alter table cryptoscreen.sealed_messages
      add column if not exists read_policy cryptoscreen.sealed_message_read_policy not null default 'app_only'
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
  const feedbackID = await storeFeedback(body, env);

  try {
    await sendFeedbackEmail(body, env, feedbackID);
    await markFeedbackEmailNotified(feedbackID, env);
  } catch (error) {
    console.error(JSON.stringify({
      level: "error",
      message: "Anonymous feedback email failed",
      feedbackID,
      error: describeError(error)
    }));
  }

  return jsonResponse({ ok: true }, 202, {
    "Cache-Control": "no-store"
  });
}

async function ensureFeedbackSchema(env: Env): Promise<void> {
  if (!feedbackSchemaReady) {
    const sql = neon(env.DATABASE_URL);
    feedbackSchemaReady = applyFeedbackSchema(sql).catch((error) => {
      feedbackSchemaReady = null;
      throw error;
    });
  }

  await feedbackSchemaReady;
}

async function applyFeedbackSchema(sql: SqlClient): Promise<void> {
  await sql`
    create table if not exists cryptoscreen.anonymous_feedback (
      id uuid primary key,
      rating smallint not null check (rating between 1 and 5),
      message text not null check (char_length(message) between 1 and 2000),
      app_version text,
      build_number text,
      platform text,
      device text,
      client_timestamp timestamptz not null,
      email_notified_at timestamptz,
      created_at timestamptz not null default now()
    )
  `;

  await sql`
    create index if not exists anonymous_feedback_created_at_idx
      on cryptoscreen.anonymous_feedback (created_at desc)
  `;
}

async function storeFeedback(feedback: FeedbackBody, env: Env): Promise<string> {
  await ensureFeedbackSchema(env);

  const id = crypto.randomUUID();
  const sql = neon(env.DATABASE_URL);
  await sql`
    insert into cryptoscreen.anonymous_feedback (
      id,
      rating,
      message,
      app_version,
      build_number,
      platform,
      device,
      client_timestamp
    )
    values (
      ${id}::uuid,
      ${feedback.rating},
      ${feedback.message},
      ${feedback.appVersion ?? null},
      ${feedback.buildNumber ?? null},
      ${feedback.platform ?? null},
      ${feedback.device ?? null},
      ${feedback.timestamp}::timestamptz
    )
  `;

  return id;
}

async function markFeedbackEmailNotified(feedbackID: string, env: Env): Promise<void> {
  const sql = neon(env.DATABASE_URL);
  await sql`
    update cryptoscreen.anonymous_feedback
    set email_notified_at = now()
    where id = ${feedbackID}::uuid
  `;
}

async function createMessage(request: Request, env: Env): Promise<Response> {
  const body = parseCreateBody(await readJson(request));
  await ensureReadPolicySchema(env);
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
      read_policy,
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
      ${body.readPolicy}::cryptoscreen.sealed_message_read_policy,
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
  if (body.readerClient === "web") {
    const readPolicy = await activeMessageReadPolicy(env, messageID);
    if (readPolicy === "app_only") {
      throw new HttpError(403, "app_only_message", "This message can only be opened in the cryptoscreen app or App Clip.");
    }
  }

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

async function activeMessageReadPolicy(env: Env, messageID: string): Promise<ReadPolicy | null> {
  await ensureReadPolicySchema(env);
  const sql = neon(env.DATABASE_URL);
  const rows = await sql`
    select read_policy
    from cryptoscreen.sealed_messages
    where id = ${messageID}::uuid
      and (retained or expires_at > now())
    limit 1
  `;

  if (rows.length === 0) {
    return null;
  }

  return parseDatabaseReadPolicy(expectDatabaseRecord(rows[0]).read_policy);
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

  await ensureReadPolicySchema(env);
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
      select id, read_policy
      from cryptoscreen.sealed_messages
      where id = ${messageID}::uuid
        and (retained or expires_at > now())
      limit 1
    )
    select
      case
        when exists (select 1 from active_message) then 'active'
        when audit.destroyed_at is not null then 'destroyed'
        when audit.expired_at is not null or exists (select 1 from deleted_expired) then 'expired'
        else 'consumed'
      end as status,
      (select read_policy from active_message) as read_policy,
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
    readPolicy: parseOptionalReadPolicy(body.readPolicy),
    ttlSeconds
  };
}

function parseConsumeBody(value: unknown): ConsumeMessageBody {
  const body = expectRecord(value);

  return {
    pinProof: expectString(body.pinProof, "pinProof"),
    clientOptIn: body.clientOptIn === true,
    readerClient: parseOptionalReaderClient(body.readerClient)
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

function parseOptionalReadPolicy(value: unknown): ReadPolicy {
  if (value === undefined || value === null) {
    return "app_only";
  }

  return parseReadPolicy(expectString(value, "readPolicy"));
}

function parseReadPolicy(value: string): ReadPolicy {
  const readPolicy = value.trim().toLowerCase();
  if (!isReadPolicy(readPolicy)) {
    throw new HttpError(400, "invalid_read_policy", "readPolicy must be app_only or web_allowed.");
  }

  return readPolicy;
}

function parseOptionalReaderClient(value: unknown): ReaderClient | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }

  const readerClient = expectString(value, "readerClient").trim().toLowerCase();
  if (!isReaderClient(readerClient)) {
    throw new HttpError(400, "invalid_reader_client", "readerClient must be ios_app or web.");
  }

  return readerClient;
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

async function sendFeedbackEmail(feedback: FeedbackBody, env: Env, feedbackID: string): Promise<void> {
  const recipient = env.FEEDBACK_EMAIL || env.SUPPORT_EMAIL;
  const from = env.FEEDBACK_FROM_EMAIL;
  if (!recipient || !from) {
    throw new HttpError(500, "feedback_not_configured", "Private feedback email is not configured.");
  }

  await env.FEEDBACK_EMAIL_SENDER.send({
    from,
    to: recipient,
    subject: `cryptoscreen anonymous feedback (${feedback.rating}/5)`,
    text: feedbackEmailText(feedback, feedbackID)
  });
}

function feedbackEmailText(feedback: FeedbackBody, feedbackID: string): string {
  return [
    "cryptoscreen anonymous feedback",
    "",
    `Feedback ID: ${feedbackID}`,
    `Rating: ${feedback.rating}/5`,
    `Timestamp: ${feedback.timestamp}`,
    `App version: ${feedback.appVersion ?? "unknown"}`,
    `Build number: ${feedback.buildNumber ?? "unknown"}`,
    `Platform: ${feedback.platform ?? "unknown"}`,
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
    readPolicy: parseNullableReadPolicy(row.read_policy),
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

function parseNullableReadPolicy(value: unknown): ReadPolicy | null {
  if (value === null) {
    return null;
  }

  return parseDatabaseReadPolicy(value);
}

function parseDatabaseReadPolicy(value: unknown): ReadPolicy {
  const readPolicy = expectDatabaseString(value, "read_policy");
  if (!isReadPolicy(readPolicy)) {
    throw new HttpError(500, "invalid_database_result", "The database field read_policy was invalid.");
  }

  return readPolicy;
}

function isReadPolicy(value: string): value is ReadPolicy {
  return readPolicies.includes(value as ReadPolicy);
}

function isReaderClient(value: string): value is ReaderClient {
  return readerClients.includes(value as ReaderClient);
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
          <p class="eyebrow">Now also on the web</p>
          <h1>cryptoscreen</h1>
          <p class="lede">
            Send sealed messages from iPhone. Read them in the app or, when the sender allows it, on the web. Share a link and PIN for one private read before the encrypted message is deleted.
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
            <a class="button primary" data-ios-only href="${escapeAttribute(links.appStoreUrl)}" rel="noreferrer">Download on the App Store</a>
          </div>
        </div>
      </section>
      <section class="section split">
        <div>
          <p class="eyebrow">Browser reading is here</p>
          <h2>Read a message without installing the app.</h2>
        </div>
        <div class="copy-stack">
          <p>Choose <strong>App or web</strong> when creating a message on iPhone. Your recipient can open the link on iPhone, Android, or desktop and enter the six-digit PIN in a supported browser.</p>
          <p>The browser decrypts the message locally. The server still receives no plaintext or link secret, and the same one-time read and three-attempt PIN limit apply. Choose <strong>App only</strong> to keep reading restricted to the iPhone app.</p>
          <p>For capture redaction and screenshot-triggered destruction, read in the iPhone app. Browsers do not provide those protections.</p>
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
          <p>Write the note in the iPhone app, choose a six-digit PIN, and select App only or App or web. Encrypt on device.</p>
        </article>
        <article>
          <span>02</span>
          <h3>Share</h3>
          <p>Send the link and PIN through separate channels. The URL fragment keeps the secret out of server logs.</p>
        </article>
        <article>
          <span>03</span>
          <h3>Read once</h3>
          <p>Open in the app or, if the sender selected App or web, in a supported browser. Enter the PIN, decrypt locally, and read once.</p>
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
          <a href="/transparency">Transparency</a>
          <a href="/support">Support</a>
          <a href="/.well-known/apple-app-site-association">Apple association</a>
          <a href="/m/example-message-id">Universal link page</a>
        </nav>
      </section>
    `,
    undefined,
    homeStatsScript(),
    undefined,
    true
  );
}

function messagePage(url: URL, env: Env): string {
  const rawMessageID = url.pathname.split("/").pop() ?? "";
  const messageUrl = messageUrlWithoutFragment(url, env);
  const webUrl = new URL(url.pathname, env.WEB_BASE_URL).href;
  const clipUrl = `${messageUrl}?clip=1`;
  const clipPage = url.origin === siteBaseUrl(env).origin && url.searchParams.get("clip") === "1";
  const messageLinks = { appUrl: messageUrl, webUrl, clipPage, appClipBanner: url.origin === siteBaseUrl(env).origin };
  const links = siteLinks(env);

  if (clipPage) {
    return pageShell("Open App Clip", env, `
      <section class="panel">
        <p class="eyebrow">Sealed message</p>
        <h1>Open with App Clip</h1>
        <p data-ios-help>Tap Open in the App Clip card or Safari banner to read your message without installing the full app.</p>
        <p class="hint">If the card is unavailable, open this page in Safari outside Private Browsing, or return to the message for other options.</p>
        <div class="actions">
          <a class="button primary" data-message-link href="${escapeAttribute(webUrl)}">Back to message</a>
          <a class="button" data-ios-only href="${escapeAttribute(links.appStoreUrl)}">Download on the App Store</a>
        </div>
      </section>`, true, "", messageLinks);
  }

  return pageShell(
    "Open sealed message",
    env,
    `
      <section class="panel" data-message-id="${escapeAttribute(rawMessageID)}">
        <p class="eyebrow">Sealed message</p>
        <h1>Open your message</h1>
        <p>
          Read with cryptoscreen on iPhone, or enter the six-digit PIN here if the sender allowed browser reading.
        </p>
        <div class="actions" data-app-actions hidden>
          <a class="button primary" data-open-message data-message-link href="${escapeAttribute(messageUrl)}">Open in app</a>
          <a class="button" data-app-clip data-message-link href="${escapeAttribute(clipUrl)}">Open App Clip</a>
          <a class="button" href="${escapeAttribute(links.appStoreUrl)}">Download on the App Store</a>
        </div>
        <p class="hint" data-ios-help>If the app does not open from this browser, open this page in Safari and tap Open in app.</p>
        <noscript><p>Enable JavaScript to open this message. You can also open the original link from Messages on an iPhone.</p></noscript>
        <p class="hint" data-open-state>Checking this message...</p>
        <form class="browser-reader" data-browser-reader hidden>
          <label class="input-label" for="pin">Six-digit PIN</label>
          <input id="pin" name="pin" type="text" inputmode="numeric" pattern="[0-9]{6}" autocomplete="one-time-code" maxlength="6" placeholder="000000" data-pin>
          <button class="button primary" type="submit">Read in browser</button>
          <p class="browser-warning">
            Reading consumes this message. Keep this page open until you finish. Browsers cannot provide the iOS app's screenshot and screen-recording protections.
          </p>
        </form>
        <div class="message-output" data-message-output hidden>
          <p class="eyebrow">Message</p>
          <pre data-plaintext></pre>
          <img data-attachment alt="Encrypted attachment" hidden>
          <button class="button" type="button" data-close-message>Close and clear message</button>
        </div>
        <p class="hint" data-reader-status></p>
      </section>
    `,
    true,
    messageReaderScript(),
    messageLinks
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
        <p>The production API stores encrypted message bytes, nonce, tag, salt, read policy, expiry time, failed attempt count, and a server-peppered PIN verifier. When a sender attaches an image, the service stores encrypted image object bytes in private R2 storage plus encrypted attachment metadata in Neon. User message rows and attachment metadata are deleted after a successful read, after the third wrong PIN, or after expiry cleanup. Unused user links expire after ${LINK_RETENTION_DAYS} days.</p>
        <p>After a successful read with an image attachment, the app downloads the encrypted image bytes through a short-lived one-time read session. The R2 object is deleted after that one-time download. Expired attachment objects and read sessions are deleted by scheduled cleanup.</p>
        <h2>Status data and telemetry</h2>
        <p>cryptoscreen does not use ad SDKs, tracking SDKs, third-party analytics SDKs, or contact upload. There is no account profile.</p>
        <p>One-time links necessarily reveal some delivery state. If a link no longer opens, the sender or recipient can infer that the message was already opened, expired, destroyed after wrong PIN attempts, or manually expired by the sender. This is part of enforcing one-time reads and does not require telemetry opt-in.</p>
        <p>To support one-time deletion and the optional sent-message list, the service keeps minimal delivery-status metadata for a message id: whether the text was consumed, whether an encrypted image attachment existed, whether that image was consumed, whether the row expired or was destroyed, and whether a screenshot event was reported. This status metadata does not include plaintext, image plaintext, PINs, link secrets, sender identity, recipient identity, or contact data. Delivery-status metadata is deleted by scheduled cleanup after it has been inactive for about ${LINK_RETENTION_DAYS} days.</p>
        <p>Interaction status sharing is opt-in in the app's Privacy settings and works reciprocally. If it is off, the app does not send optional read or screenshot status and does not fetch or show detailed interaction status for messages you sent. If it is on, you can see detailed interaction status only when the reader also shared interaction status from their app. Screenshot reports contain only a generic screenshot event and timestamp for that message. Screenshot detection is best-effort: iOS reports normal screenshots after capture, modified clients can omit reporting, and external cameras cannot be detected.</p>
        <p>The service also keeps an aggregate count of how many sealed messages have been shared. That counter does not include message content, recipients, senders, or link secrets.</p>
        <p>If you send feedback from inside the app, the service sends your written feedback anonymously to the maintainer with the app version/build, platform, rating, and timestamp. Feedback does not include your account, contacts, sender or recipient identity, sealed message content, image content, PINs, full links, or link secrets.</p>
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
          <p>Neon stores encrypted message bytes, nonce, tag, salt, read policy, expiry time, failed attempt count, and a server-peppered PIN verifier. Cloudflare R2 stores encrypted image object bytes when an image is attached.</p>
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

function transparencyPage(env: Env): string {
  return pageShell(
    "Transparency",
    env,
    `
      <section class="panel prose">
        <p class="eyebrow">Transparency</p>
        <h1>What the database sees</h1>
        <p>cryptoscreen is designed so the hosted service stores encrypted payloads only. A database row alone, or a database row plus the PIN alone, is not enough to decrypt a message.</p>

        <h2>Text messages</h2>
        <p>The app encrypts the message on the sender's device before upload. The server receives fields shaped like this:</p>
        <pre><code>{
  "id": "message uuid",
  "ciphertext": "encrypted message bytes",
  "nonce": "AES-GCM nonce",
  "tag": "AES-GCM tag",
  "salt": "per-message salt",
  "pin_verifier": "server-peppered PIN proof",
  "read_policy": "app_only or web_allowed",
  "expires_at": "30 day maximum"
}</code></pre>
        <p>That row does not contain the plaintext, raw PIN, link secret, sender identity, recipient identity, contacts, or account profile.</p>

        <h2>What can decrypt</h2>
        <ul class="security-list">
          <li>Database row only: cannot decrypt.</li>
          <li>Database row plus PIN: cannot decrypt because the link secret is missing.</li>
          <li>Database row plus link secret plus PIN: can decrypt locally in the app.</li>
        </ul>

        <h2>Images</h2>
        <p>Images follow the same boundary. The app encrypts the image before upload. R2 stores encrypted image bytes. Neon stores the object key, encrypted file-key bytes, size, content type, and expiry metadata. The raw image and raw image key are not stored by the service.</p>

        <h2>One-time opening</h2>
        <p>After a correct PIN proof, the database function returns the encrypted payload and deletes the normal message row in the same locked operation. The third wrong PIN destroys the row. Unopened links expire after ${LINK_RETENTION_DAYS} days.</p>
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

type MessagePageLinks = { appUrl: string; webUrl: string; clipPage: boolean; appClipBanner: boolean };

function pageShell(title: string, env: Env, content: string, preserveFragment = false, bodyScript = "", messageLinks?: MessagePageLinks, intro = false): string {
  const escapedTitle = escapeHtml(title);
  const description = "Send one-time encrypted messages from iPhone. Read in the app or, when the sender allows it, in a web browser. Decrypt locally with a link and PIN.";
  const links = siteLinks(env);
  const xHandle = xHandleFromUrl(links.xUrl);
  const appleAppId = appleAppStoreId(env);

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    ${messageLinks ? `<meta name="cryptoscreen-app-url" content="${escapeAttribute(messageLinks.appUrl)}">
    <meta name="cryptoscreen-web-url" content="${escapeAttribute(messageLinks.webUrl)}">
    ${smartAppBannerMeta(env, messageLinks)}` : ""}
    ${fragmentForwardingScript()}
    ${CALM_GATE_SCRIPT}
    ${intro ? INTRO_GATE_SCRIPT : ""}
    <meta name="description" content="${escapeAttribute(description)}">
    <meta name="theme-color" content="#08100b">
    <link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
    <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
    <link rel="manifest" href="/site.webmanifest">
    <meta property="og:title" content="${escapedTitle}">
    <meta property="og:description" content="${escapeAttribute(description)}">
    <meta property="og:type" content="website">
    <meta property="og:image" content="${escapeAttribute(siteBaseUrl(env).origin)}/icons/icon-512.png">
    ${preserveFragment ? '<meta name="robots" content="noindex, nofollow, noarchive">' : ""}
    <meta name="twitter:card" content="app">
    <meta name="twitter:site" content="${escapeAttribute(xHandle)}">
	    <meta name="twitter:description" content="${escapeAttribute(description)}">
	    <meta name="twitter:app:name:iphone" content="cryptoscreen">
	    <meta name="twitter:app:id:iphone" content="${escapeAttribute(appleAppId)}">
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
        --panel: oklch(13% 0.018 154 / 0.72);
        --panel-solid: oklch(13% 0.018 154);
        --panel-2: oklch(18% 0.02 154);
        --ink: oklch(94% 0.12 148);
        --soft-ink: oklch(85% 0.13 149);
        --muted: oklch(73% 0.11 150);
        --quiet: oklch(58% 0.08 151);
        --line: oklch(85% 0.15 150 / 0.13);
        --line-strong: oklch(85% 0.15 150 / 0.24);
        --glow: 0 0 7px oklch(81% 0.21 152 / 0.38);
        --accent: oklch(81% 0.21 152);
        --accent-dim: oklch(81% 0.21 152 / 0.14);
        --accent-line: oklch(81% 0.21 152 / 0.32);
        --accent-ink: oklch(16% 0.06 153);
        --warn: oklch(78% 0.15 77);
        --blue: oklch(91% 0.17 150);
        --display: "Alpha Lyrae", ui-rounded, "SF Pro Rounded", ui-sans-serif, system-ui, sans-serif;
        --mono: ui-monospace, "SFMono-Regular", "JetBrains Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
        --radius: 14px;
        --radius-sm: 10px;
        --ease-out: cubic-bezier(0.22, 1, 0.36, 1);
      }
      * { box-sizing: border-box; }
      [hidden], html.is-android [data-ios-only] { display: none !important; }
      html:not(.is-ios) [data-ios-help] { display: none; }
      html { background: var(--bg); scroll-behavior: smooth; }
      body {
        margin: 0;
        min-height: 100vh;
        background:
          radial-gradient(1100px 600px at 78% -10%, oklch(81% 0.21 152 / 0.09), transparent 62%),
          radial-gradient(800px 500px at -10% 40%, oklch(80% 0.1 220 / 0.05), transparent 60%),
          var(--bg);
        color: var(--ink);
        font-family: var(--mono);
        text-rendering: optimizeLegibility;
        -webkit-font-smoothing: antialiased;
        text-shadow: var(--glow);
        overflow-x: hidden;
      }
      body::before {
        content: "";
        position: fixed;
        inset: 0;
        pointer-events: none;
        background-image:
          linear-gradient(oklch(94% 0.018 96 / 0.035) 1px, transparent 1px),
          linear-gradient(90deg, oklch(94% 0.018 96 / 0.035) 1px, transparent 1px);
        background-size: 56px 56px;
        mask-image: radial-gradient(ellipse 80% 60% at 50% 0%, #000 20%, transparent 75%);
        -webkit-mask-image: radial-gradient(ellipse 80% 60% at 50% 0%, #000 20%, transparent 75%);
        z-index: -1;
      }
      ::selection { background: var(--accent); color: var(--accent-ink); }
      a { color: var(--blue); text-underline-offset: 0.2em; text-decoration-thickness: 1px; }
      a:focus-visible, .button:focus-visible, button:focus-visible {
        outline: 2px solid var(--accent);
        outline-offset: 3px;
        border-radius: var(--radius-sm);
      }
      code { color: var(--accent); font-family: var(--mono); font-size: 0.92em; }
      .wrap {
        width: min(1160px, calc(100% - 40px));
        margin: 0 auto;
        padding: 0 0 48px;
      }

      /* Header */
      header {
        position: sticky;
        top: 12px;
        z-index: 20;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 16px;
        margin: 12px 0 22px;
        padding: 10px 12px 10px 18px;
        border: 1px solid var(--line);
        border-radius: 999px;
        background: oklch(9% 0.016 154 / 0.72);
        backdrop-filter: blur(16px) saturate(140%);
        -webkit-backdrop-filter: blur(16px) saturate(140%);
        box-shadow: 0 10px 40px -18px oklch(0% 0 0 / 0.8);
      }
      .brand {
        align-items: center;
        color: var(--ink);
        display: inline-flex;
        font-family: var(--display);
        font-size: 19px;
        font-weight: 500;
        gap: 10px;
        text-decoration: none;
      }
      .brand-mark {
        background: var(--accent);
        border-radius: 50%;
        box-shadow: 0 0 0 4px var(--accent-dim), 0 0 16px var(--accent);
        height: 8px;
        width: 8px;
        animation: pulse 2.8s ease-in-out infinite;
      }
      @keyframes pulse {
        0%, 100% { box-shadow: 0 0 0 3px var(--accent-dim), 0 0 10px oklch(81% 0.21 152 / 0.6); }
        50% { box-shadow: 0 0 0 6px oklch(81% 0.21 152 / 0.05), 0 0 20px var(--accent); }
      }

      /* Header logo: the app's launch sequence in miniature. Pixels decrypt, the feather writes in,
         and the reveal scan line sweeps the icon until the page has loaded. */
      .brand-logo { flex: none; width: 28px; height: 28px; overflow: visible; filter: drop-shadow(0 0 10px oklch(81% 0.21 152 / 0.16)); }
      .brand-logo .bl-tile { transform-box: fill-box; transform-origin: center; animation: bl-tile 640ms var(--ease-out) 520ms both; }
      .brand-logo .bl-cells rect { transform-box: fill-box; transform-origin: center; fill: var(--c); opacity: var(--o); animation: bl-cell 300ms var(--ease-out) var(--d) both; }
      .brand-logo .bl-cells rect.b { animation: bl-fade 420ms ease-out var(--d) both; }
      .brand-logo .bl-feather { transform-box: fill-box; transform-origin: 20% 90%; animation: bl-drop 650ms var(--ease-out) 1150ms both; }
      .brand-logo .bl-reveal { transform-box: fill-box; transform-origin: top; animation: bl-reveal 560ms cubic-bezier(0.33, 1, 0.68, 1) 1150ms both; }
      .brand-logo .bl-scan-wrap { opacity: 1; transition: opacity 220ms ease-out; }
      html.cs-loaded .brand-logo .bl-scan-wrap { display: none; }
      .brand-logo .bl-scan { opacity: 0; animation: bl-scan-in 240ms ease-out 1700ms both, bl-scan-move 1050ms ease-in-out 1700ms infinite alternate both; }
      @keyframes bl-tile { from { opacity: 0; transform: scale(0.92); } to { opacity: 1; transform: scale(1); } }
      @keyframes bl-cell {
        0% { opacity: 0; transform: scale(0.4); fill: #d9ffe9; }
        60% { opacity: 1; transform: scale(1.12); fill: #d9ffe9; }
        100% { opacity: var(--o); transform: scale(1); fill: var(--c); }
      }
      @keyframes bl-fade { from { opacity: 0; } to { opacity: var(--o); } }
      @keyframes bl-drop { from { opacity: 0; transform: translate(140px, -170px) rotate(-14deg); } to { opacity: 1; transform: none; } }
      @keyframes bl-reveal { from { transform: scaleY(0); } to { transform: scaleY(1); } }
      @keyframes bl-scan-in { from { opacity: 0; } to { opacity: 0.85; } }
      @keyframes bl-scan-move { from { transform: translateY(150px); } to { transform: translateY(835px); } }

      /* Accessibility: calm mode switches off every motion, distortion and screen effect. */
      html.cs-calm *, html.cs-calm *::before, html.cs-calm *::after { animation: none !important; transition: none !important; }
      html.cs-calm .crt, html.cs-calm .crt-grid, html.cs-calm .melted-glass, html.cs-calm .intro { display: none !important; }
      html.cs-calm .rv { opacity: 1; transform: none; }
      html.cs-calm .cipher-c.is-wait, html.cs-calm .cipher-c.is-scramble { color: inherit; text-shadow: inherit; }
      html.cs-calm .cipher-c.is-scramble::after { content: none; }
      html.cs-calm .brand-logo .bl-scan-wrap { display: none; }
      html.cs-calm { scroll-behavior: auto; }
      html.cs-calm.cs-intro { overflow: auto; }
      html.cs-calm .brand .brand-logo { visibility: visible; }
      /* Keep the CRT identity on constrained devices without continuous compositing. */
      html.cs-lite .crt, html.cs-lite .hero-illustration, html.cs-lite .brand-mark,
      html.cs-lite .hero h1::after { animation: none; }
      html.cs-lite .brand-logo .bl-scan-wrap { display: none; }
      html.cs-lite header, html.cs-lite .calm-toggle,
      html.cs-calm header, html.cs-calm .calm-toggle {
        backdrop-filter: none;
        -webkit-backdrop-filter: none;
        background: var(--bg);
      }
      html.cs-lite .crt-grid {
        background: repeating-linear-gradient(180deg, oklch(0% 0 0 / 0.18) 0 1px, transparent 1px 4px);
      }
      html.cs-lite .melted-glass { display: none; }
      html.cs-paused *, html.cs-paused *::before, html.cs-paused *::after { animation-play-state: paused !important; }
      .calm-toggle {
        position: fixed;
        right: calc(16px + env(safe-area-inset-right, 0px));
        bottom: calc(16px + env(safe-area-inset-bottom, 0px));
        z-index: 70;
        display: inline-flex;
        align-items: center;
        gap: 8px;
        padding: 9px 14px 9px 10px;
        border: 1px solid var(--line-strong);
        border-radius: 999px;
        background: oklch(9% 0.016 154 / 0.86);
        backdrop-filter: blur(14px);
        -webkit-backdrop-filter: blur(14px);
        box-shadow: 0 10px 30px -14px oklch(0% 0 0 / 0.9);
        color: var(--soft-ink);
        font: 500 13px/1 var(--mono);
        cursor: pointer;
      }
      .calm-toggle:hover { border-color: var(--accent-line); color: var(--ink); }
      .calm-toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
      .calm-toggle svg { width: 18px; height: 18px; flex: none; }
      .calm-toggle .calm-state { color: var(--quiet); }
      .calm-toggle[aria-pressed="true"] { border-color: var(--accent-line); color: var(--ink); }
      .calm-toggle[aria-pressed="true"] .calm-state { color: var(--accent); }
      .calm-notice {
        position: fixed;
        right: calc(16px + env(safe-area-inset-right, 0px));
        bottom: calc(66px + env(safe-area-inset-bottom, 0px));
        z-index: 70;
        max-width: min(320px, calc(100vw - 32px));
        margin: 0;
        padding: 10px 14px;
        border: 1px solid var(--accent-line);
        border-radius: 14px;
        background: oklch(9% 0.016 154 / 0.94);
        box-shadow: 0 10px 30px -14px oklch(0% 0 0 / 0.9);
        color: var(--ink);
        font: 500 13px/1.4 var(--mono);
        opacity: 0;
        transform: translateY(6px);
        pointer-events: none;
        transition: opacity 240ms ease-out, transform 240ms ease-out;
      }
      .calm-notice.is-visible { opacity: 1; transform: none; }
      @media print { .calm-toggle, .calm-notice { display: none; } }

      /* Homepage intro: the app's launch sequence, once per browser session. The head script adds
         html.cs-intro before first paint; without it the overlay never shows. Sits under the CRT layers. */
      .intro { display: none; }
      html.cs-intro { overflow: hidden; }
      html.cs-intro .intro {
        position: fixed;
        inset: 0;
        z-index: 50;
        display: block;
        cursor: pointer;
        background: radial-gradient(120% 70% at 46% 38%, #062b1d 0%, #021a0e 45%, #000f07 100%);
        /* Failsafe: never trap the page if the script cannot run. */
        animation: intro-failsafe 0s linear 9s forwards;
      }
      html.cs-intro .brand .brand-logo { visibility: hidden; }
      @keyframes intro-failsafe { to { opacity: 0; visibility: hidden; pointer-events: none; } }
      .intro-backdrop { position: absolute; inset: 0; background: inherit; }
      .intro-power { position: absolute; left: 0; right: 0; top: 50%; height: 2px; margin-top: -1px; background: #d9ffe9; box-shadow: 0 0 18px 4px oklch(81% 0.21 152 / 0.7), 0 0 60px 10px oklch(81% 0.21 152 / 0.35); opacity: 0; transform: scaleX(0); }
      .intro-logo { position: fixed; left: 50%; top: 38%; width: min(200px, 46vw); height: min(200px, 46vw); margin: calc(min(200px, 46vw) / -2) 0 0 calc(min(200px, 46vw) / -2); overflow: visible; transform-origin: 0 0; }
      .intro-logo .bl-cells rect { transform-box: fill-box; transform-origin: center; fill: var(--c); opacity: 0; }
      .intro-logo .bl-tile, .intro-logo .bl-feather, .intro-logo .bl-reveal { transform-box: fill-box; }
      .intro-logo .bl-tile { transform-origin: center; opacity: 0; }
      .intro-logo .bl-feather { transform-origin: 20% 90%; opacity: 0; }
      .intro-logo .bl-reveal { transform-origin: top; transform: scaleY(0); }
      .intro-logo .bl-scan { opacity: 0; }
      .intro-logo .bl-glyphs text { font: 600 34px var(--mono); fill: var(--accent); text-anchor: middle; dominant-baseline: central; filter: drop-shadow(0 0 10px oklch(81% 0.21 152 / 0.85)); }
      .intro-word { position: absolute; left: 0; right: 0; top: calc(38% + min(200px, 46vw) / 2 + 38px); text-align: center; font-family: var(--display); font-size: clamp(28px, 7vw, 40px); font-weight: 500; color: #fff; text-shadow: 0 0 14px oklch(81% 0.21 152 / 0.18); white-space: pre; }
      .intro-progress { position: absolute; left: 50%; top: calc(38% + min(200px, 46vw) / 2 + 102px); display: flex; gap: 4px; transform: translateX(-50%); opacity: 0; }
      .intro-progress i { width: 9px; height: 9px; border-radius: 1.5px; background: oklch(70% 0.12 152 / 0.16); }
      .intro-progress i.on { background: #5fbd86; box-shadow: 0 0 8px oklch(81% 0.21 152 / 0.6); }
      .intro-status { position: absolute; left: 0; right: 0; top: calc(38% + min(200px, 46vw) / 2 + 124px); text-align: center; font: 500 11px var(--mono); letter-spacing: 0.08em; text-transform: uppercase; color: oklch(80% 0.1 152 / 0.55); opacity: 0; }
      header nav {
        display: flex;
        flex-wrap: wrap;
        gap: 2px;
        font-size: 13px;
      }
      header nav a {
        border-radius: 999px;
        color: var(--muted);
        padding: 7px 12px;
        text-decoration: none;
        transition: color 160ms ease-out, background 160ms ease-out;
      }
      header nav a:hover { background: var(--accent-dim); color: var(--ink); }
      .brand:hover { color: var(--ink); }

      /* Hero */
      .hero {
        position: relative;
        min-height: min(780px, calc(100vh - 110px));
        display: flex;
        align-items: end;
        overflow: hidden;
        border: 1px solid var(--line);
        border-radius: 22px;
        background:
          radial-gradient(700px 420px at 75% 30%, oklch(81% 0.21 152 / 0.12), transparent 70%),
          var(--bg-2);
        isolation: isolate;
        box-shadow: inset 0 1px 0 oklch(94% 0.018 96 / 0.06), 0 40px 120px -60px oklch(81% 0.21 152 / 0.35);
      }
      .hero::after {
        content: "";
        position: absolute;
        inset: 0;
        background:
          linear-gradient(180deg, transparent 30%, var(--bg-2) 98%),
          linear-gradient(90deg, var(--bg-2) 0%, oklch(10.5% 0.018 154 / 0.7) 40%, transparent 100%);
        z-index: -1;
      }
      .hero-copy {
        max-width: 700px;
        padding: clamp(28px, 7vw, 76px);
        position: relative;
        z-index: 3;
      }
      .hero-illustration {
        position: absolute;
        right: clamp(22px, 7vw, 92px);
        top: clamp(40px, 8vw, 104px);
        width: min(36vw, 430px);
        z-index: -2;
        filter: drop-shadow(0 0 26px oklch(81% 0.21 152 / 0.32));
        opacity: 0.92;
        pointer-events: none;
        animation: float 9s ease-in-out infinite;
      }
      @keyframes float {
        0%, 100% { transform: translateY(0); }
        50% { transform: translateY(-12px); }
      }
      .hero-illustration img {
        display: block;
        height: auto;
        width: 100%;
      }
      .hero h1::after {
        content: "_";
        color: var(--accent);
        margin-left: 0.04em;
        animation: caret 1.05s steps(1) infinite;
      }
      @keyframes caret { 50% { opacity: 0; } }

      /* Type */
      .eyebrow {
        color: var(--accent);
        font-size: 11.5px;
        font-weight: 700;
        letter-spacing: 0.14em;
        margin: 0 0 16px;
        text-transform: uppercase;
      }
      .hero .eyebrow {
        align-items: center;
        background: var(--accent-dim);
        border: 1px solid var(--accent-line);
        border-radius: 999px;
        display: inline-flex;
        gap: 8px;
        padding: 6px 12px 6px 10px;
      }
      .hero .eyebrow::before {
        content: "";
        background: var(--accent);
        border-radius: 50%;
        box-shadow: 0 0 10px var(--accent);
        height: 6px;
        width: 6px;
      }
      h1 {
        font-family: var(--display);
        font-size: clamp(46px, 11vw, 112px);
        font-feature-settings: "calt" 1, "liga" 1;
        font-weight: 500;
        line-height: 0.94;
        letter-spacing: -0.01em;
        margin: 0 0 22px;
        text-shadow: -0.04em 0 0 oklch(68% 0.2 25 / 0.32), 0.04em 0 0 oklch(70% 0.16 250 / 0.32), 0 0 34px oklch(81% 0.21 152 / 0.4);
      }
      h2 {
        color: var(--ink);
        font-family: var(--display);
        font-size: clamp(28px, 5vw, 50px);
        font-feature-settings: "calt" 1, "liga" 1;
        font-weight: 500;
        line-height: 1.04;
        margin: 0;
        text-wrap: balance;
        text-shadow: -1.5px 0 0 oklch(68% 0.2 25 / 0.28), 1.5px 0 0 oklch(70% 0.16 250 / 0.28), 0 0 18px oklch(81% 0.21 152 / 0.35);
      }
      h3 {
        color: var(--ink);
        font-family: var(--display);
        font-size: 22px;
        font-feature-settings: "calt" 1, "liga" 1;
        font-weight: 500;
        line-height: 1.12;
        margin: 14px 0 10px;
      }
      p {
        color: var(--muted);
        font-size: 15.5px;
        line-height: 1.7;
        margin: 0;
      }
      strong { color: var(--soft-ink); }
      .lede {
        color: var(--soft-ink);
        font-size: clamp(17px, 2.6vw, 21px);
        line-height: 1.55;
        max-width: 620px;
      }

      /* CRT screen */
      .button.primary, ::selection { text-shadow: none; }
      .crt {
        position: fixed;
        inset: 0;
        pointer-events: none;
        z-index: 62;
        background: radial-gradient(ellipse 120% 100% at 50% 50%, transparent 58%, oklch(4% 0.02 154 / 0.55) 100%);
        box-shadow: inset 0 0 120px oklch(4% 0.02 154 / 0.7), inset 0 0 18px oklch(81% 0.21 152 / 0.08);
        animation: crt-flicker 6s steps(1) infinite;
      }
      .crt-grid {
        position: fixed;
        inset: 0;
        pointer-events: none;
        z-index: 60;
        /* Phosphor pixel matrix: 4px cells with a dark scan gap and faint green cell borders. */
        background:
          repeating-linear-gradient(180deg, oklch(0% 0 0 / 0.26) 0 1px, transparent 1px 4px),
          repeating-linear-gradient(180deg, transparent 0 1px, oklch(81% 0.21 152 / 0.075) 1px 2px, transparent 2px 4px),
          repeating-linear-gradient(90deg, oklch(81% 0.21 152 / 0.07) 0 1px, transparent 1px 4px),
          radial-gradient(circle at 2.5px 2.5px, oklch(81% 0.21 152 / 0.045) 0 1px, transparent 1.5px) 0 0 / 4px 4px;
      }
      @keyframes crt-flicker {
        0%, 100% { opacity: 1; }
        41% { opacity: 0.94; }
        42% { opacity: 1; }
        77% { opacity: 0.97; }
        78% { opacity: 1; }
      }
      .melted-glass {
        position: fixed;
        inset: 0;
        pointer-events: none;
        z-index: 61;
      }

      /* Cipher animation */
      .cipher-sr {
        position: absolute;
        width: 1px;
        height: 1px;
        overflow: hidden;
        clip-path: inset(50%);
        white-space: nowrap;
      }
      .cipher-c { position: relative; }
      .cipher-c.is-wait, .cipher-c.is-scramble { color: transparent; text-shadow: none; }
      .cipher-c.is-scramble::after {
        content: attr(data-g);
        position: absolute;
        left: 50%;
        top: 0;
        transform: translateX(-50%);
        color: var(--accent);
        text-shadow: 0 0 14px oklch(81% 0.21 152 / 0.7);
      }
      .rv {
        opacity: 0;
        transform: translateY(16px);
        transition: opacity 700ms var(--ease-out), transform 700ms var(--ease-out), border-color 200ms ease-out, background 200ms ease-out;
      }
      .rv.rv-in { opacity: 1; transform: none; }

      /* Stats */
      .stat-strip {
        display: grid;
        grid-template-columns: repeat(4, minmax(112px, max-content));
        gap: 14px 30px;
        margin-top: 30px;
      }
      .stat-item {
        border-left: 1px solid var(--accent-line);
        min-width: 112px;
        padding-left: 14px;
      }
      .stat-value {
        color: var(--ink);
        display: block;
        font-size: clamp(26px, 4.6vw, 38px);
        font-variant-numeric: tabular-nums;
        font-weight: 700;
        letter-spacing: -0.02em;
        line-height: 1;
        min-height: 1em;
      }
      .stat-label {
        color: var(--quiet);
        display: block;
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 0.1em;
        line-height: 1.35;
        margin-top: 9px;
        text-transform: uppercase;
      }

      /* Buttons */
      .actions {
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        margin-top: 30px;
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
        border: 1px solid var(--line-strong);
        border-radius: var(--radius-sm);
        background: oklch(94% 0.018 96 / 0.03);
        color: var(--ink);
        cursor: pointer;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        font: 700 14px/1 var(--mono);
        gap: 8px;
        min-height: 44px;
        padding: 12px 17px;
        text-decoration: none;
        transition: background 180ms ease-out, border-color 180ms ease-out, color 180ms ease-out, transform 180ms var(--ease-out), box-shadow 180ms ease-out;
      }
      .button.primary {
        background: var(--accent);
        border-color: var(--accent);
        color: var(--accent-ink);
        box-shadow: 0 0 0 1px oklch(81% 0.21 152 / 0.4), 0 10px 30px -10px oklch(81% 0.21 152 / 0.65);
      }
      .button.ghost {
        background: transparent;
        border-color: var(--line);
        color: var(--soft-ink);
      }
      .button:hover {
        background: var(--panel-2);
        border-color: var(--accent-line);
        transform: translateY(-1px);
      }
      .button.primary:hover {
        background: oklch(87% 0.2 152);
        color: var(--accent-ink);
        box-shadow: 0 0 0 1px oklch(81% 0.21 152 / 0.5), 0 14px 38px -10px oklch(81% 0.21 152 / 0.85);
      }
      .button:active { transform: translateY(0); }

      /* Sections */
      .section {
        padding: clamp(48px, 9vw, 104px) 0;
      }
      .section + .section { border-top: 1px solid var(--line); }
      .split {
        display: grid;
        grid-template-columns: minmax(0, 0.82fr) minmax(0, 1fr);
        gap: clamp(28px, 8vw, 96px);
        align-items: start;
      }
      .split > div:first-child { position: sticky; top: 104px; }
      .copy-stack {
        display: grid;
        gap: 18px;
        max-width: 640px;
      }
      .steps {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 14px;
      }
      article {
        position: relative;
        border: 1px solid var(--line);
        border-radius: var(--radius);
        background:
          linear-gradient(180deg, oklch(94% 0.018 96 / 0.035), transparent 60%),
          var(--panel);
        padding: 26px;
        overflow: hidden;
      }
      article::before {
        content: "";
        position: absolute;
        inset: 0;
        background: radial-gradient(420px 220px at var(--mx, 50%) var(--my, -40%), oklch(81% 0.21 152 / 0.12), transparent 70%);
        opacity: 0;
        pointer-events: none;
        transition: opacity 260ms ease-out;
      }
      article:hover { border-color: var(--accent-line); }
      article:hover::before { opacity: 1; }
      article span {
        color: var(--accent);
        display: inline-block;
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.12em;
      }
      .steps article span {
        border: 1px solid var(--accent-line);
        border-radius: 999px;
        background: var(--accent-dim);
        padding: 5px 10px;
      }
      article p {
        font-size: 14.5px;
      }
      .apple-strip {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(220px, 380px);
        gap: 28px;
      }

      /* Security page */
      .security-hero {
        border: 1px solid var(--line);
        border-radius: 22px;
        background:
          radial-gradient(600px 360px at 0% 0%, oklch(81% 0.21 152 / 0.1), transparent 70%),
          var(--panel);
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(260px, 360px);
        gap: clamp(28px, 7vw, 78px);
        padding: clamp(24px, 6vw, 58px);
      }
      .security-hero h1 {
        font-size: clamp(38px, 7.4vw, 76px);
        max-width: 780px;
      }
      .toc {
        align-content: start;
        display: grid;
        gap: 8px;
      }
      .toc a, .link-list a {
        align-items: center;
        border: 1px solid var(--line);
        border-radius: var(--radius-sm);
        background: oklch(94% 0.018 96 / 0.02);
        color: var(--soft-ink);
        display: flex;
        gap: 12px;
        padding: 13px 16px;
        text-decoration: none;
        transition: border-color 180ms ease-out, color 180ms ease-out, background 180ms ease-out, transform 180ms var(--ease-out);
      }
      .link-list a::after {
        content: "\\2192";
        color: var(--quiet);
        margin-left: auto;
        transition: transform 180ms var(--ease-out), color 180ms ease-out;
      }
      .toc a:hover, .link-list a:hover {
        background: var(--accent-dim);
        border-color: var(--accent-line);
        color: var(--ink);
      }
      .link-list a:hover::after { color: var(--accent); transform: translateX(3px); }
      .toc span, .section-number {
        color: var(--accent);
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.12em;
      }
      .numbered-section {
        border-top: 1px solid var(--line);
        display: grid;
        grid-template-columns: minmax(0, 0.8fr) minmax(0, 1fr);
        gap: clamp(28px, 8vw, 96px);
        padding: clamp(48px, 9vw, 104px) 0;
      }
      .section-number {
        display: block;
        margin-bottom: 18px;
      }
      .security-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 14px;
        padding-bottom: clamp(48px, 9vw, 104px);
      }
      .security-grid article {
        min-height: 260px;
      }
      .security-list {
        color: var(--muted);
        display: grid;
        gap: 12px;
        line-height: 1.65;
        margin: 0;
        padding-left: 0;
        list-style: none;
      }
      .security-list li {
        padding-left: 24px;
        position: relative;
      }
      .security-list li::before {
        content: ">";
        color: var(--accent);
        font-weight: 700;
        left: 0;
        position: absolute;
      }
      .security-callout {
        border: 1px solid var(--accent-line);
        border-radius: var(--radius);
        background:
          radial-gradient(600px 300px at 100% 100%, oklch(81% 0.21 152 / 0.12), transparent 70%),
          oklch(81% 0.21 152 / 0.04);
        display: grid;
        grid-template-columns: minmax(0, 0.9fr) minmax(0, 1fr);
        gap: 28px;
        padding: clamp(24px, 5vw, 40px);
      }
      .link-list {
        display: grid;
        align-content: start;
        gap: 8px;
        font-size: 15px;
      }

      /* Panels and prose */
      .panel {
        border: 1px solid var(--line);
        border-radius: 22px;
        background:
          linear-gradient(180deg, oklch(94% 0.018 96 / 0.035), transparent 30%),
          var(--panel);
        padding: clamp(24px, 6vw, 52px);
        max-width: 780px;
        margin: clamp(8px, 4vw, 40px) auto;
        box-shadow: 0 40px 120px -70px oklch(81% 0.21 152 / 0.4);
      }
      .prose h1 {
        font-size: clamp(36px, 7.6vw, 62px);
        line-height: 1;
      }
      .prose h2 { font-size: 25px; margin: 38px 0 12px; }
      .prose p + p { margin-top: 16px; }
      .prose pre {
        border: 1px solid var(--line);
        border-radius: var(--radius-sm);
        background: var(--bg);
        color: var(--soft-ink);
        font-size: 13px;
        line-height: 1.6;
        margin: 18px 0;
        overflow-x: auto;
        padding: 16px 18px;
      }
      .prose pre code { color: inherit; }
      .note {
        border: 1px solid var(--accent-line);
        border-radius: var(--radius-sm);
        background: oklch(81% 0.21 152 / 0.06);
        color: var(--soft-ink);
        margin-top: 18px;
        padding: 14px;
      }
      .hint {
        color: var(--quiet);
        font-size: 13px;
        line-height: 1.55;
        margin-top: 14px;
      }

      /* Browser reader */
      .browser-warning {
        border: 1px solid oklch(78% 0.15 77 / 0.34);
        border-radius: var(--radius-sm);
        background: oklch(78% 0.15 77 / 0.08);
        color: var(--warn);
        font-size: 13px;
        line-height: 1.55;
        margin-top: 14px;
        padding: 12px 14px;
      }
      .browser-warning[hidden] { display: none; }
      .browser-reader {
        display: grid;
        gap: 12px;
        margin-top: 26px;
      }
      .browser-reader[hidden] { display: none; }
      .browser-reader .button { justify-self: start; }
      .input-label {
        color: var(--soft-ink);
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.12em;
        text-transform: uppercase;
      }
      input {
        background: var(--bg);
        border: 1px solid var(--line-strong);
        border-radius: var(--radius-sm);
        color: var(--ink);
        font: 700 30px/1 var(--mono);
        letter-spacing: 0.3em;
        max-width: 240px;
        padding: 14px 16px;
        transition: border-color 160ms ease-out, box-shadow 160ms ease-out;
      }
      input::placeholder { color: oklch(94% 0.018 96 / 0.18); }
      input:focus {
        border-color: var(--accent);
        box-shadow: 0 0 0 4px oklch(81% 0.21 152 / 0.16), 0 0 30px -6px oklch(81% 0.21 152 / 0.5);
        outline: none;
      }
      .message-output {
        border-top: 1px solid var(--line);
        display: grid;
        gap: 14px;
        margin-top: 26px;
        padding-top: 22px;
      }
      .message-output[hidden] { display: none; }
      .message-output pre {
        background: var(--bg);
        border: 1px solid var(--accent-line);
        border-radius: var(--radius-sm);
        color: var(--ink);
        font: 16px/1.6 var(--mono);
        margin: 0;
        overflow-wrap: anywhere;
        padding: 18px;
        white-space: pre-wrap;
        user-select: none;
      }
      .message-output img {
        border: 1px solid var(--line);
        border-radius: var(--radius-sm);
        max-height: 70vh;
        max-width: 100%;
        object-fit: contain;
      }
      .message-output img[hidden] { display: none; }

      /* Footer */
      footer {
        border-top: 1px solid var(--line);
        color: var(--quiet);
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 14px 18px;
        font-size: 12px;
        margin-top: 24px;
        padding-top: 26px;
      }
      .footer-brand {
        align-items: center;
        display: inline-flex;
        gap: 10px;
      }
      .footer-links {
        display: flex;
        flex-wrap: wrap;
        gap: 6px 18px;
      }
      footer a {
        color: var(--muted);
        text-decoration: none;
        transition: color 160ms ease-out;
      }
      footer a:hover { color: var(--accent); }

      @media (max-width: 860px) {
        .split > div:first-child { position: static; }
      }
      @media (max-width: 760px) {
        .wrap { width: calc(100% - 32px); }
        header {
          border-radius: 18px;
          flex-direction: column;
          align-items: flex-start;
          gap: 8px;
          position: static;
          padding: 12px 10px 10px 14px;
        }
        header nav { margin-left: -10px; }
        header nav a { padding: 6px 10px; }
        .hero { min-height: 640px; border-radius: 18px; }
        .hero::after {
          background:
            linear-gradient(180deg, transparent 10%, var(--bg-2) 96%),
            linear-gradient(90deg, var(--bg-2) 0%, oklch(10.5% 0.018 154 / 0.78) 68%, oklch(10.5% 0.018 154 / 0.3) 100%);
        }
        .hero-copy { padding: 24px; }
        .stat-strip {
          gap: 16px 12px;
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
        .stat-item {
          min-width: 0;
          padding-left: 10px;
        }
        .stat-value { font-size: 26px; }
        .stat-label { font-size: 10px; }
        .actions { align-items: stretch; flex-direction: column; }
        .button { width: 100%; }
        .browser-reader .button { justify-self: stretch; }
        .sponsor-cta { justify-content: center; }
        .hero-illustration {
          opacity: 0.24;
          right: -84px;
          top: 76px;
          width: 320px;
        }
        .split, .steps, .apple-strip, .security-hero, .numbered-section, .security-grid, .security-callout { grid-template-columns: 1fr; }
        .section { padding: 48px 0; }
        .security-grid { padding-bottom: 48px; }
        .security-grid article { min-height: 0; }
        footer { flex-direction: column; align-items: flex-start; }
      }
      @media (prefers-reduced-motion: reduce) {
        *, *::before, *::after { animation: none !important; transition: none !important; }
        html { scroll-behavior: auto; }
      }
    </style>
  </head>
  <body>
    ${intro ? INTRO_MARKUP : ""}
    <div class="wrap">
      <header>
        <a class="brand" href="/">${BRAND_LOGO_SVG}cryptoscreen</a>
        <nav aria-label="Main">
          <a href="/privacy">Privacy</a>
          <a href="/security">Security</a>
          <a href="/transparency">Transparency</a>
          <a href="/terms">Terms</a>
          <a href="/support">Support</a>
          <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
          <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
        </nav>
      </header>
      <main>${content}</main>
      <footer>
        <span class="footer-brand"><span class="brand-mark" aria-hidden="true"></span>cryptoscreen.app / one-time encrypted messages</span>
        <nav class="footer-links" aria-label="Footer">
          <a href="/privacy">Privacy</a>
          <a href="/security">Security</a>
          <a href="/transparency">Transparency</a>
          <a href="/terms">Terms</a>
          <a href="/support">Support</a>
          <a href="${escapeAttribute(links.githubUrl)}" rel="noreferrer">GitHub</a>
          <a href="${escapeAttribute(links.xUrl)}" rel="noreferrer">X</a>
          <a href="/.well-known/apple-app-site-association">AASA</a>
        </nav>
      </footer>
    </div>
    ${bodyScript}
    ${cipherScript()}
    ${meltedGlassScript()}
    ${BRAND_LOGO_LOADED_SCRIPT}
    ${intro ? INTRO_SCRIPT : ""}
    ${CALM_TOGGLE_MARKUP}
    ${CALM_TOGGLE_SCRIPT}
    ${CONSOLE_ART_SCRIPT}
    <div class="crt-grid" aria-hidden="true"></div>
    <div class="crt" aria-hidden="true"></div>
  </body>
</html>`;
}

function formatStatNumber(value: number): string {
  return new Intl.NumberFormat("en-US").format(value);
}

function messageUrlWithoutFragment(url: URL, env: Env): string {
  const baseUrl = siteBaseUrl(env);
  return `${baseUrl.origin}${url.pathname}`;
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

// Decorative "decrypt" reveal: headings and labels resolve from shuffled glyphs.
// Static string so its CSP hash stays stable; it bails out without the browser APIs it needs.
// The cryptoscreen logo (pixel lock + feather) from the Figma splash icon, in a 999-unit square.
// Cells carry their colour, final opacity and animation delay so the intro runs in pure CSS:
// it starts with first paint and still ends on the finished logo without JavaScript or with
// reduced motion. Mirrors CSLogo in the app's CryptoscreenLogo.swift.
function brandLogoSvg(className: string, id: string): string {
  const green = "#5fbd86", light = "#64b686", dark = "#2f8954", deep = "#0d4725";
  type Cell = [number, number, string, number];
  const lock: Cell[] = [
    [254, 460, light, 1], [295, 460, green, 1], [336, 460, green, 1], [377, 460, green, 1], [418, 460, green, 1], [459, 460, green, 1],
    [254, 501, light, 1], [295, 501, green, 1], [336, 501, green, 1], [377, 501, green, 1], [418, 501, green, 1], [459, 501, green, 1],
    [254, 542, green, 1], [295, 542, green, 1], [336, 542, green, 1], [377, 542, green, 1], [418, 542, green, 1], [459, 542, green, 1],
    [254, 583, green, 1], [295, 583, green, 1], [254, 623, green, 1], [295, 623, green, 1], [254, 664, green, 1], [295, 664, green, 1],
    [254, 705, green, 1], [582, 583, green, 0.33], [664, 623, green, 0.25], [459, 664, green, 0.7], [295, 746, green, 0.32],
    [541, 746, green, 0.12], [664, 746, green, 0.1],
    [418, 173, light, 1], [459, 173, green, 1], [459, 214, dark, 1], [500, 173, green, 1], [500, 214, dark, 1], [541, 173, green, 1],
    [295, 419, green, 1], [295, 378, green, 1], [295, 337, green, 1], [295, 296, light, 1], [336, 255, light, 1], [377, 214, light, 1],
    [336, 419, dark, 1], [336, 378, dark, 1], [336, 337, dark, 1], [377, 255, dark, 1], [336, 296, dark, 1], [418, 214, dark, 1],
    [541, 214, green, 1], [584, 214, green, 1]
  ];
  // Drawn above the feather, as in the logo.
  const bottomRow: Cell[] = [
    [254, 787, green, 1], [377, 787, deep, 0.8], [295, 787, green, 1], [336, 787, green, 1], [418, 787, green, 0.8], [459, 787, green, 0.8],
    [500, 787, deep, 0.8], [541, 787, green, 0.8], [582, 787, deep, 0.8], [623, 787, green, 0.8], [664, 787, deep, 0.4], [705, 787, green, 0.4]
  ];
  const shackleRight: Cell[] = [
    [583, 255, green, 1], [624, 255, dark, 1], [623, 296, green, 1], [623, 337, green, 1], [623, 378, green, 1],
    [623, 419, dark, 1], [664, 296, dark, 1], [664, 337, dark, 1], [664, 378, dark, 1], [664, 419, dark, 1]
  ];
  const body: [number, number][] = [
    [500, 460], [541, 460], [582, 460], [623, 460], [664, 460], [705, 460], [500, 501], [541, 501], [582, 501], [623, 501], [664, 501], [705, 501],
    [500, 542], [541, 542], [582, 542], [623, 542], [664, 542], [705, 542], [336, 583], [377, 583], [418, 583], [459, 583], [500, 583], [541, 583],
    [623, 583], [705, 583], [336, 623], [377, 623], [418, 623], [459, 623], [500, 623], [541, 623], [582, 623], [623, 623], [705, 623],
    [336, 664], [377, 664], [418, 664], [500, 664], [541, 664], [582, 664], [623, 664], [664, 664], [705, 664], [295, 705], [336, 705],
    [377, 705], [418, 705], [459, 705], [500, 705], [541, 705], [582, 705], [623, 705], [664, 705], [705, 705], [254, 746], [336, 746],
    [377, 746], [418, 746], [459, 746], [500, 746], [582, 746], [623, 746], [705, 746]
  ];

  // Decrypt order: top to bottom with a fixed jitter, so every page renders the same markup.
  let seed = 0xc0ffee;
  const random = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 4294967296;
  };
  const delays = new Map<Cell, number>();
  [...lock, ...bottomRow, ...shackleRight]
    .map(cell => ({ cell, key: cell[1] + random() * 120 }))
    .sort((a, b) => a.key - b.key)
    .forEach(({ cell }, rank) => delays.set(cell, Math.round(220 + rank * 11 + 160 + random() * 180)));

  const rect = (x: number, y: number, colour: string, opacity: number, delay: number, className = "") =>
    `<rect${className ? ` class="${className}"` : ""} x="${x}" y="${y}" width="36" height="36" rx="2" style="--c:${colour};--o:${opacity};--d:${delay}ms"/>`;
  const cells = (list: Cell[]) => list.map(cell => rect(cell[0], cell[1], cell[2], cell[3], delays.get(cell) ?? 0)).join("");
  const bodyCells = body.map(([x, y]) => {
    const opacity = Math.max(0.06, 0.95 - Math.hypot(x + 18 - 300, y + 18 - 470) / 520);
    return rect(x, y, green, Number(opacity.toFixed(2)), Math.round(560 + ((x - 254) + (y - 460)) / 900 * 400), "b");
  }).join("");

  const feather = "M110.416 501.481C101.826 518.037 15.1138 660.776 34.9355 674.851C54.7573 688.925 59.4133 667.17 63.2562 659.584C78.4411 629.606 106.675 569.814 127.869 545.853C146.935 524.299 181.654 499.033 217.158 477.429C204.499 477.318 195.142 480.622 173.851 477.049C224.84 461.99 325.383 402.838 340.213 383.328C331.522 386.638 295.546 387.677 272.269 382.731C286.933 382.183 340.397 362.307 363.374 353.499C377.886 335.238 385.419 320.435 392.75 300.074C386.063 302.724 343.833 316.681 313.233 310.994C329.89 311.141 397.982 280.892 407.82 258.508C442.228 180.225 515.177 81.1608 555.067 37.0224C574.222 15.8268 477.22 30.0845 373.196 100.025C302.029 147.874 242.894 199.333 191.792 279.81C140.691 360.287 143.952 430.888 143.878 439.3C143.804 447.712 143.23 449.133 141.029 444.265C138.827 439.398 134.472 426.649 129.156 399.283C127.443 402.69 121.22 419.639 121.102 433.05C120.985 446.461 123.324 476.605 110.416 501.481Z";

  return `<svg class="${className}" viewBox="0 0 999 999" aria-hidden="true" focusable="false">` +
    `<defs>` +
    `<radialGradient id="${id}-tile" cx="0.42" cy="0.62" r="0.62"><stop offset="0" stop-color="#062b1d"/><stop offset="1" stop-color="#001107"/></radialGradient>` +
    `<linearGradient id="${id}-feather" x1="187.87" y1="265.91" x2="379.01" y2="383.67" gradientUnits="userSpaceOnUse"><stop offset="0.09" stop-color="#eafff3"/><stop offset="0.32" stop-color="#fff"/><stop offset="0.84" stop-color="#d5f7ee"/></linearGradient>` +
    `<linearGradient id="${id}-shine" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="0.5" stop-color="#fff" stop-opacity="0.95"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>` +
    `<clipPath id="${id}-clip"><path transform="translate(218 139)" d="${feather}"/></clipPath>` +
    `<mask id="${id}-reveal" maskUnits="userSpaceOnUse" x="0" y="0" width="999" height="999"><g transform="rotate(-38 500 500)"><rect class="bl-reveal" x="-400" y="-800" width="1800" height="2000" fill="#fff"/></g></mask>` +
    `</defs>` +
    `<rect class="bl-tile" width="999" height="999" rx="220" fill="url(#${id}-tile)" stroke="#7affb3" stroke-opacity="0.12" stroke-width="6"/>` +
    `<g class="bl-cells">${bodyCells}${cells(lock)}</g>` +
    `<g class="bl-feather" style="filter:drop-shadow(8px 12px 20px rgb(0 39 16 / 0.6))"><g mask="url(#${id}-reveal)"><path fill="url(#${id}-feather)" transform="translate(218 139)" d="${feather}"/>` +
    `<g clip-path="url(#${id}-clip)"><g transform="rotate(28 300 380)"><rect class="bl-shine" x="-200" y="0" width="140" height="760" fill="url(#${id}-shine)" opacity="0"/></g></g></g></g>` +
    `<g class="bl-cells">${cells(bottomRow)}</g>` +
    `<g class="bl-cells" style="filter:drop-shadow(-10px 13px 10px rgb(4 74 33 / 0.31))">${cells(shackleRight)}</g>` +
    `<g class="bl-glyphs"></g>` +
    `<g class="bl-scan-wrap"><rect class="bl-scan" x="70" y="0" width="859" height="16" rx="8" fill="#7affb3"/></g>` +
    `</svg>`;
}

const BRAND_LOGO_SVG = brandLogoSvg("brand-logo", "bl");
const INTRO_LOGO_SVG = brandLogoSvg("intro-logo", "il");

// Marks the page as loaded so the header logo stops its scan line. Static so its CSP hash is stable.
const BRAND_LOGO_LOADED_SCRIPT = `<script>
(() => {
  const loaded = () => document.documentElement.classList.toggle("cs-loaded", true);
  if (document.readyState === "complete") loaded();
  else window.addEventListener("load", loaded);
})();
</script>`;

// Hello to anyone opening the console: the logo as ASCII art. Static so its CSP hash is stable.
const CONSOLE_ART_SCRIPT = `<script>
(() => {
  const art = [
    "                                                                                      ",
    "                                                                                      ",
    "              @@@@@@@@     ////                                                       ",
    "            @@@@@@@@@@@//////         cryptoscreen                                    ",
    "          @@@@      //@@@@/.                                                          ",
    "        @@@@      //////@@@@          Messages you read once.                         ",
    "        @@@@    ////////@@@@          Encrypted on your device, opened with a PIN,    ",
    "        @@@@  //////////@@@@          deleted from the server after one read.         ",
    "        @@@@ /////////  @@@@                                                          ",
    "      @@@@@@//////////...             Curious how it works? Read the code:            ",
    "      @@@@@//////// .::...            https://github.com/DomenicoDD/cryptoscreen      ",
    "      @@@@:///////.:::::.                                                             ",
    "      @@@@/////.:@::::::              Follow me on X:                                 ",
    "      @@@////.:::::...    ..          https://x.com/domenicodd                        ",
    "      @@//  ....@@                                                                    ",
    "      ://                                                                             ",
    "      // .                                                                            ",
    "      /:@@@@::@@@@::@@::@@  ::                                                        ",
    "                                                                                      ",
    "                                                                                      "
  ];
  // Own dark panel so it reads on both light and dark DevTools themes.
  console.log("%c" + art.join(String.fromCharCode(10)), "color:#7affb3;background:#03140b;font-family:ui-monospace,Menlo,monospace;font-size:11px;line-height:1.3;padding:2px 0");
})();
</script>`;

// Accessibility: a floating switch that turns off every motion and distortion effect, remembered
// in this browser. The head script applies it before first paint so nothing starts moving.
const CALM_GATE_SCRIPT = `<script>
(() => {
  const root = document.documentElement;
  let autoOff = false;
  try {
    if (localStorage.getItem("cs-calm") === "1") root.classList.toggle("cs-calm", true);
    // An automatic shutdown sticks for an hour, so every page does not re-test a struggling device.
    autoOff = Date.now() - Number(localStorage.getItem("cs-auto-off") || 0) < 3600000;
  } catch (error) {}
  if (autoOff) root.classList.add("cs-lite", "cs-auto-off");
  if (typeof window.matchMedia !== "function") return;
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  const constrained = window.matchMedia("(hover: none), (pointer: coarse)").matches ||
    (navigator.hardwareConcurrency > 0 && navigator.hardwareConcurrency <= 4) ||
    (navigator.deviceMemory > 0 && navigator.deviceMemory <= 4) ||
    !!(navigator.connection && navigator.connection.saveData);
  const sync = () => {
    root.classList.toggle("cs-lite", constrained || reduced.matches || autoOff);
    if (reduced.matches) root.classList.add("cs-calm");
  };
  sync();
  reduced.addEventListener("change", sync);
  document.addEventListener("visibilitychange", () => root.classList.toggle("cs-paused", document.hidden));
})();
</script>`;

const CALM_TOGGLE_MARKUP = `<button class="calm-toggle" type="button" data-calm-toggle aria-pressed="false" title="Turn off motion and screen effects">` +
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="4.5" r="1.8"/><path d="M5 8.5l7 1.5 7-1.5M12 10v4.5M12 14.5l-3 6M12 14.5l3 6"/></svg>` +
  `Accessibility <span class="calm-state" data-calm-state>effects on</span></button>` +
  `<p class="calm-notice" data-calm-notice role="status" aria-live="polite"></p>`;

const CALM_TOGGLE_SCRIPT = `<script>
(() => {
  const button = document.querySelector("[data-calm-toggle]");
  if (!button) return;
  const root = document.documentElement;
  const label = button.querySelector("[data-calm-state]");
  const notice = document.querySelector("[data-calm-notice]");
  const autoOff = () => root.classList.contains("cs-auto-off");
  const sync = () => {
    const off = root.classList.contains("cs-calm") || autoOff();
    button.setAttribute("aria-pressed", off ? "true" : "false");
    button.title = autoOff() ? "Effects were turned off to keep your computer cool. Turn them back on" : off ? "Turn motion and screen effects back on" : "Turn off motion and screen effects";
    if (label) label.textContent = off ? "effects off" : "effects on";
  };
  sync();

  // The page drops to lite mode by itself when this device cannot keep up. Lite mode that is
  // already set at startup (touch, small devices) is expected; one that appears later is a shutdown.
  let wasLite = root.classList.contains("cs-lite");
  if (typeof MutationObserver === "function") new MutationObserver(() => {
    const lite = root.classList.contains("cs-lite");
    if (lite && !wasLite && !root.classList.contains("cs-calm") && !autoOff()) {
      root.classList.add("cs-auto-off");
      try { localStorage.setItem("cs-auto-off", String(Date.now())); } catch (error) {}
      sync();
      if (notice) {
        notice.textContent = "It seems we were burning your PC, so we turned the effects off.";
        notice.classList.add("is-visible");
        window.setTimeout(() => notice.classList.remove("is-visible"), 7000);
      }
    }
    wasLite = lite;
  }).observe(root, { attributes: true, attributeFilter: ["class"] });

  button.addEventListener("click", () => {
    if (autoOff()) {
      try {
        localStorage.removeItem("cs-auto-off");
        localStorage.setItem("cs-calm", "0");
      } catch (error) {}
      window.location.reload();
      return;
    }
    const calm = !root.classList.contains("cs-calm");
    root.classList.toggle("cs-calm", calm);
    try {
      localStorage.setItem("cs-calm", calm ? "1" : "0");
    } catch (error) {}
    sync();
    // Effects that were never started stay off; turning them back on restarts them cleanly.
    if (!calm) window.location.reload();
  });
})();
</script>`;

const INTRO_MARKUP = `<div class="intro" data-intro aria-hidden="true">` +
  `<div class="intro-backdrop" data-intro-backdrop></div><div class="intro-power" data-intro-power></div>` +
  `${INTRO_LOGO_SVG}<div class="intro-word" data-intro-word></div>` +
  `<div class="intro-progress" data-intro-progress>${"<i></i>".repeat(12)}</div><div class="intro-status" data-intro-status>sealing channel</div>` +
  `</div>`;

// Runs before first paint on the homepage: plays the intro once per session, never with reduced motion.
const INTRO_GATE_SCRIPT = `<script>
(() => {
  try {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    if (localStorage.getItem("cs-calm") === "1") return;
    if (document.documentElement.classList.contains("cs-lite")) return;
    if (sessionStorage.getItem("cs-intro")) return;
    sessionStorage.setItem("cs-intro", "1");
    document.documentElement.classList.toggle("cs-intro", true);
  } catch (error) {}
})();
</script>`;

// The homepage intro sequence. Mirrors CryptoscreenSplashView in the app; times are in ms.
const INTRO_SCRIPT = `<script>
(() => {
  const root = document.documentElement;
  const intro = document.querySelector("[data-intro]");
  if (!intro) return;
  const end = () => { root.classList.toggle("cs-intro", false); intro.remove(); };
  if (!root.classList.contains("cs-intro") || typeof intro.animate !== "function") { end(); return; }

  const EASE = "cubic-bezier(0.22, 1, 0.36, 1)";
  const GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#$%&*+-/<>[]{}";
  const pick = () => GLYPHS[Math.floor(Math.random() * GLYPHS.length)];
  const NS = "http://www.w3.org/2000/svg";
  const logo = intro.querySelector(".intro-logo");
  const q = selector => intro.querySelector(selector);
  const anim = (el, frames, options) => el.animate(frames, { fill: "both", easing: EASE, ...options });
  const timers = [];
  const later = (ms, fn) => timers.push(window.setTimeout(fn, ms));
  let finished = false;
  let loaded = document.readyState === "complete";
  window.addEventListener("load", () => { loaded = true; });

  // Shared cipher loop: glyphs change every 55 ms, as in the site's headings and the app.
  const cipher = items => {
    let origin = 0;
    const frame = now => {
      if (!origin) origin = now;
      const t = now - origin;
      let pending = 0;
      for (const item of items) {
        if (item.done) continue;
        if (t < item.start) { pending++; continue; }
        if (t >= item.end) { item.done = true; item.finish(); continue; }
        pending++;
        if (t - (item.tick || -99) > 55) { item.tick = t; item.glyph(pick()); }
      }
      if (pending && !finished) requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  };

  // 1. CRT power-on
  anim(q("[data-intro-power]"), [
    { opacity: 1, transform: "scaleX(0)" },
    { opacity: 1, transform: "scaleX(1)", offset: 0.55 },
    { opacity: 0, transform: "scaleX(1) scaleY(40)" }
  ], { duration: 380, easing: "ease-out" });
  anim(q("[data-intro-backdrop]"), [{ filter: "brightness(0)" }, { filter: "brightness(1.6)", offset: 0.5 }, { filter: "brightness(1)" }], { duration: 620, delay: 120, easing: "ease-out" });

  // 2. Tile
  anim(q(".bl-tile"), [{ opacity: 0, transform: "scale(0.92)" }, { opacity: 1, transform: "scale(1)" }], { duration: 640, delay: 520 });

  // 3. Pixels decrypt; the body fades along its diagonal. Each cell's --d is when it settles.
  const glyphLayer = q(".bl-glyphs");
  const items = [];
  for (const rect of logo.querySelectorAll(".bl-cells rect")) {
    const style = rect.style;
    const opacity = Number(style.getPropertyValue("--o"));
    const delay = parseFloat(style.getPropertyValue("--d"));
    if (rect.classList.contains("b")) {
      rect.animate([{ opacity: 0 }, { opacity }], { duration: 420, delay, easing: "ease-out", fill: "both" });
      continue;
    }
    const text = document.createElementNS(NS, "text");
    text.setAttribute("x", Number(rect.getAttribute("x")) + 18);
    text.setAttribute("y", Number(rect.getAttribute("y")) + 18);
    glyphLayer.appendChild(text);
    items.push({
      start: delay - 260, end: delay,
      glyph: g => { text.textContent = g; },
      finish: () => {
        text.remove();
        rect.animate([
          { opacity: 0, transform: "scale(0.4)", fill: "#d9ffe9" },
          { opacity: Math.min(1, opacity + 0.25), transform: "scale(1.12)", fill: "#d9ffe9", offset: 0.6 },
          { opacity, transform: "scale(1)", fill: style.getPropertyValue("--c") }
        ], { duration: 260, easing: EASE, fill: "both" });
      }
    });
  }
  cipher(items);

  // 4. Feather writes in, then a glint crosses it
  anim(q(".bl-feather"), [{ opacity: 0, transform: "translate(140px, -170px) rotate(-14deg)" }, { opacity: 1, transform: "none" }], { duration: 650, delay: 1150 });
  anim(q(".bl-reveal"), [{ transform: "scaleY(0)" }, { transform: "scaleY(1)" }], { duration: 560, delay: 1150, easing: "cubic-bezier(0.33, 1, 0.68, 1)" });
  anim(q(".bl-shine"), [{ opacity: 0, transform: "translateX(0)" }, { opacity: 0.9, offset: 0.3 }, { opacity: 0, transform: "translateX(820px)" }], { duration: 620, delay: 1800, easing: "ease-in-out" });

  // 5. Wordmark resolves with the site's scramble
  const word = q("[data-intro-word]");
  const text = "cryptoscreen.app";
  const spans = [...text].map(character => {
    const span = document.createElement("span");
    span.className = "cipher-c is-wait";
    span.textContent = character;
    word.appendChild(span);
    return span;
  });
  later(1700, () => cipher(spans.map((span, i) => {
    const start = i * 70;
    return {
      start, end: start + 760 * (0.55 + Math.random() * 0.6),
      glyph: g => { span.className = "cipher-c is-scramble"; span.setAttribute("data-g", g); },
      finish: () => { span.className = ""; }
    };
  })));

  // 6. Loading: scan line sweeps the icon while twelve cells fill; holds until the page has loaded
  const scan = q(".bl-scan");
  const progress = [...intro.querySelectorAll("[data-intro-progress] i")];
  const status = q("[data-intro-status]");
  later(2500, () => {
    if (finished) return;
    scan.animate([{ opacity: 0 }, { opacity: 0.85 }], { duration: 240, fill: "forwards" });
    scan.animate([{ transform: "translateY(150px)" }, { transform: "translateY(835px)" }], { duration: 1050, easing: "ease-in-out", iterations: Infinity, direction: "alternate" });
    anim(q("[data-intro-progress]"), [{ opacity: 0 }, { opacity: 1 }], { duration: 300 });
    anim(status, [{ opacity: 0 }, { opacity: 1 }], { duration: 300 });
    let lit = 0;
    const fill = () => {
      if (finished) return;
      if (lit < progress.length && (loaded || lit < 8)) progress[lit++].className = "on";
      if (lit === 5) status.textContent = "verifying device";
      if (lit === 10) status.textContent = "ready";
      if (lit < progress.length) later(lit < 8 ? 95 : 140, fill);
      else later(160, exit);
    };
    fill();
  });

  // 7. Land in the header logo
  function exit() {
    if (finished) return;
    finished = true;
    timers.forEach(id => window.clearTimeout(id));
    for (const el of [scan, q("[data-intro-progress]"), status, word]) {
      el.animate([{ opacity: getComputedStyle(el).opacity }, { opacity: 0 }], { duration: 200, fill: "forwards" });
    }
    const target = document.querySelector(".brand .brand-logo");
    const from = logo.getBoundingClientRect();
    const to = target ? target.getBoundingClientRect() : from;
    const scale = to.width / from.width;
    logo.animate([
      { transform: "translate(0, 0) scale(1)" },
      { transform: "translate(" + (to.left - from.left) + "px, " + (to.top - from.top) + "px) scale(" + scale + ")" }
    ], { duration: 640, delay: 140, easing: "cubic-bezier(0.65, 0, 0.2, 1)", fill: "forwards" });
    q("[data-intro-backdrop]").animate([{ opacity: 1 }, { opacity: 1, offset: 0.6 }, { opacity: 0 }], { duration: 760, delay: 140, easing: "ease-in", fill: "forwards" });
    window.setTimeout(end, 900);
  }

  intro.addEventListener("click", () => {
    // Skip: settle everything now and land.
    for (const a of logo.getAnimations({ subtree: true })) if (a.effect && a.effect.getTiming().iterations !== Infinity) a.finish();
    for (const item of items) if (!item.done) { item.done = true; item.finish(); }
    for (const a of logo.getAnimations({ subtree: true })) if (a.effect && a.effect.getTiming().iterations !== Infinity) a.finish();
    word.textContent = text;
    exit();
  });
})();
</script>`;

function cipherScript(): string {
  return `<script>
(() => {
  if (typeof window.matchMedia !== "function" || typeof window.requestAnimationFrame !== "function" || typeof window.IntersectionObserver !== "function") return;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const calm = () => document.documentElement.classList.contains("cs-calm") || document.documentElement.classList.contains("cs-lite");
  if (calm()) return;

  const GLYPHS = "abcdefghkmnopqrsuvwxyz0123456789#%*+=<>/?";
  const DIGITS = "0123456789";
  const running = new WeakSet();
  const finishes = new Set();
  const pick = set => set[Math.floor(Math.random() * set.length)];
  const isTextOnly = el => el.childNodes.length > 0 && Array.from(el.childNodes).every(node => node.nodeType === 3) && el.textContent.trim().length > 0;

  const prepare = el => {
    if (running.has(el) || !isTextOnly(el)) return null;
    running.add(el);
    const text = el.textContent;
    const set = /^[0-9.,\\s]+$/.test(text) ? DIGITS : GLYPHS;
    const live = el.getAttribute("aria-live");
    if (live) el.removeAttribute("aria-live");
    const label = document.createElement("span");
    label.className = "cipher-sr";
    label.textContent = text;
    const shell = document.createElement("span");
    shell.setAttribute("aria-hidden", "true");
    const cells = [];
    for (const ch of text) {
      if (/\\s/.test(ch)) {
        shell.appendChild(document.createTextNode(ch));
        continue;
      }
      const cell = document.createElement("span");
      cell.className = "cipher-c is-wait";
      cell.textContent = ch;
      shell.appendChild(cell);
      cells.push(cell);
    }
    el.replaceChildren(label, shell);
    return { el, text, set, live, shell, cells };
  };

  const play = (job, { delay = 0, step = 32, scramble = 520, maxSpread = 720 } = {}) => {
    const { el, text, set, live, shell, cells } = job;
    const spacing = Math.min(step, maxSpread / Math.max(cells.length, 1));
    const plan = cells.map((cell, i) => {
      const start = delay + i * spacing;
      return { cell, start, end: start + scramble * (0.55 + Math.random() * 0.6), tick: 0 };
    });
    let origin = 0;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      if (shell.parentNode === el) el.textContent = text;
      if (live) el.setAttribute("aria-live", live);
      running.delete(el);
      finishes.delete(finish);
    };
    finishes.add(finish);
    window.setTimeout(finish, delay + cells.length * spacing + scramble * 1.2 + 1500);
    const frame = now => {
      if (done) return;
      if (calm() || document.hidden) { finish(); return; }
      if (!origin) origin = now;
      const t = now - origin;
      let pending = 0;
      for (const item of plan) {
        if (t < item.start) { pending++; continue; }
        if (t >= item.end) {
          if (item.cell.className) item.cell.className = "";
          continue;
        }
        pending++;
        if (item.cell.className !== "cipher-c is-scramble") item.cell.className = "cipher-c is-scramble";
        if (t - item.tick > 55) {
          item.tick = t;
          item.cell.setAttribute("data-g", pick(set));
        }
      }
      if (pending) {
        window.requestAnimationFrame(frame);
        return;
      }
      finish();
    };
    window.requestAnimationFrame(frame);
  };

  const reveal = Array.from(document.querySelectorAll("h1, h2, h3, .eyebrow, .stat-value, .section-number"));
  const fades = Array.from(document.querySelectorAll("main article, .copy-stack > p, .security-list li, .link-list a, .toc a, .lede, .hero .actions"));
  for (const el of fades) el.classList.add("rv");

  const observer = new IntersectionObserver(entries => {
    let order = 0;
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const el = entry.target;
      observer.unobserve(el);
      const job = reveal.includes(el) && !calm() ? prepare(el) : null;
      if (job) {
        const big = el.tagName === "H1";
        play(job, { delay: order * 90, step: big ? 70 : 26, scramble: big ? 760 : 480 });
      } else {
        el.style.transitionDelay = (order * 70) + "ms";
        el.classList.add("rv-in");
      }
      order++;
    }
  }, { rootMargin: "0px 0px -6% 0px" });
  for (const el of reveal) observer.observe(el);
  for (const el of fades) observer.observe(el);

  const hoverTargets = document.querySelectorAll("header nav a, .button, .link-list a, footer a");
  for (const el of hoverTargets) {
    const shuffle = () => {
      if (calm()) return;
      const job = prepare(el);
      if (job) play(job, { step: 18, scramble: 260, maxSpread: 260 });
    };
    el.addEventListener("mouseenter", shuffle);
    el.addEventListener("focus", shuffle);
  }

  // Coalesce high-frequency pointer events into one layout read/write per frame.
  let pointerFrame = 0;
  let latestPointer = null;
  document.addEventListener("pointermove", event => {
    if (calm() || event.pointerType === "touch") return;
    latestPointer = event;
    if (pointerFrame) return;
    pointerFrame = requestAnimationFrame(() => {
      pointerFrame = 0;
      if (calm()) return;
      const card = latestPointer.target instanceof Element ? latestPointer.target.closest("article") : null;
      if (!card) return;
      const box = card.getBoundingClientRect();
      card.style.setProperty("--mx", (latestPointer.clientX - box.left) + "px");
      card.style.setProperty("--my", (latestPointer.clientY - box.top) + "px");
    });
  }, { passive: true });
  new MutationObserver(() => {
    if (!calm()) return;
    observer.disconnect();
    for (const finish of finishes) finish();
    for (const el of fades) el.classList.add("rv-in");
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
})();
</script>`;
}

// Melted glass: the whole screen is a sheet of soft glass. Moving the cursor presses a groove with
// raised banks into a persistent height field (it "draws"), which slowly melts back. On top, the live
// fingertip shape (dent under the cursor, ridge ahead, tapered trough behind) follows the motion.
// A single displacement pass preserves the lens at a fraction of the old RGB filter cost.
// Work is capped, activity-driven, and disabled when the device cannot keep up. Chromium desktop only.
function meltedGlassScript(): string {
  return `<script>
(() => {
  if (typeof window.matchMedia !== "function" || typeof window.requestAnimationFrame !== "function") return;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  if (!window.matchMedia("(hover: hover) and (pointer: fine)").matches) return;
  const brands = navigator.userAgentData && navigator.userAgentData.brands;
  if (!brands || !brands.some(b => /Chrom/.test(b.brand))) return;
  const root = document.documentElement;
  const calm = () => root.classList.contains("cs-calm") || root.classList.contains("cs-lite");
  if (calm()) return;
  // Full-screen filters scale with physical pixels, even with a small displacement map.
  const oversized = () => innerWidth * innerHeight * Math.pow(devicePixelRatio || 1, 2) > 6000000;
  if (oversized()) { root.classList.add("cs-lite"); return; }

  let CELL = 8;
  const SCALE = 42;
  const LENGTH = 300;
  const WIDTH = 228;
  const FINGER = 0.18;
  const SIGMA_IN = 15;
  const SIGMA_OUT = 30;
  const STAMP_STEP = 3;
  const STAMP_DEPTH = 0.075;
  const MELT = 0.994;
  const SPREAD_RATE = 0.06;

  // Fingertip surface in local space: u along the motion, v across it, both -1..1.
  const surface = (u, v) => {
    const r2 = u * u + v * v;
    if (r2 >= 1) return 0;
    const du = u - FINGER;
    const dent = -Math.exp(-(du * du / 0.06 + v * v / 0.05));
    const rho = Math.sqrt(du * du + v * v);
    const ahead = Math.max(0, du / (rho + 0.0001));
    const ridge = 0.42 * Math.exp(-((rho - 0.36) * (rho - 0.36)) / 0.014) * ahead * ahead;
    const tu = du + 0.38;
    const tailWidth = 0.045 * Math.min(Math.max(1 + du * 1.3, 0.18), 1.6);
    const tail = -0.4 * Math.exp(-(tu * tu / 0.11 + v * v / tailWidth));
    return (dent + ridge + tail) * Math.pow(1 - r2, 3);
  };
  let peak = 0;
  for (let y = 0; y < 76; y++) {
    for (let x = 0; x < 100; x++) {
      const u = (x + 0.5) / 50 - 1;
      const v = (y + 0.5) / 38 - 1;
      peak = Math.max(peak, Math.abs(surface(u + 0.01, v) - surface(u - 0.01, v)) / 0.02);
    }
  }
  // Height slope per cell -> map counts; the full-strength fingertip peaks around 70 counts.
  let GAIN = 0;

  const NS = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("width", "0");
  svg.setAttribute("height", "0");
  svg.setAttribute("aria-hidden", "true");
  svg.style.position = "absolute";
  const filter = document.createElementNS(NS, "filter");
  for (const [key, value] of [["id", "melted-glass"], ["x", "0"], ["y", "0"], ["filterUnits", "userSpaceOnUse"], ["primitiveUnits", "userSpaceOnUse"], ["color-interpolation-filters", "sRGB"]]) filter.setAttribute(key, value);
  const add = (tag, values) => {
    const node = document.createElementNS(NS, tag);
    for (const key in values) node.setAttribute(key, values[key]);
    filter.appendChild(node);
    return node;
  };
  const feImage = add("feImage", { x: "0", y: "0", preserveAspectRatio: "none", result: "map" });
  // An 8-bit map cannot encode exactly 0.5, so pre-shift each channel to cancel the neutral drift.
  const drift = 128 / 255 - 0.5;
  add("feOffset", { in: "SourceGraphic", dx: String(SCALE * drift), dy: String(SCALE * drift), result: "source" });
  add("feDisplacementMap", { in: "source", in2: "map", scale: String(SCALE), xChannelSelector: "R", yChannelSelector: "G" });
  svg.appendChild(filter);
  document.body.appendChild(svg);

  const glass = document.createElement("div");
  glass.className = "melted-glass";
  glass.setAttribute("aria-hidden", "true");
  document.body.appendChild(glass);

  const mapCanvas = document.createElement("canvas");
  const ctx = mapCanvas.getContext("2d");
  if (!ctx) return;
  let cols = 0;
  let rows = 0;
  let field = new Float32Array(0);
  let scratch = new Float32Array(0);
  let render = new Float32Array(0);
  let image = null;

  const resize = () => {
    CELL = Math.max(8, Math.ceil(Math.sqrt(innerWidth * innerHeight / 28000)));
    GAIN = 70 / (peak * CELL / (LENGTH / 2)) / 2;
    cols = Math.ceil(window.innerWidth / CELL) + 2;
    rows = Math.ceil(window.innerHeight / CELL) + 2;
    field = new Float32Array(cols * rows);
    scratch = new Float32Array(cols * rows);
    render = new Float32Array(cols * rows);
    mapCanvas.width = cols;
    mapCanvas.height = rows;
    image = ctx.createImageData(cols, rows);
    const w = String(cols * CELL);
    const h = String(rows * CELL);
    filter.setAttribute("width", w);
    filter.setAttribute("height", h);
    feImage.setAttribute("width", w);
    feImage.setAttribute("height", h);
    feImage.setAttribute("x", String(-CELL / 2));
    feImage.setAttribute("y", String(-CELL / 2));
    filterOff();
  };

  // Draw: a volume-preserving stamp, a groove where the cursor passes with glass pushed up beside it.
  const bank = STAMP_DEPTH * (SIGMA_IN * SIGMA_IN) / (SIGMA_OUT * SIGMA_OUT);
  const stamp = (px, py, weight) => {
    const reach = Math.ceil(SIGMA_OUT * 2.6 / CELL);
    const gx = Math.round(px / CELL);
    const gy = Math.round(py / CELL);
    for (let j = -reach; j <= reach; j++) {
      const y = gy + j;
      if (y < 1 || y >= rows - 1) continue;
      for (let i = -reach; i <= reach; i++) {
        const x = gx + i;
        if (x < 1 || x >= cols - 1) continue;
        const dx = x * CELL - px;
        const dy = y * CELL - py;
        const r2 = dx * dx + dy * dy;
        const k = y * cols + x;
        const next = field[k] + weight * (bank * Math.exp(-r2 / (2 * SIGMA_OUT * SIGMA_OUT)) - STAMP_DEPTH * Math.exp(-r2 / (2 * SIGMA_IN * SIGMA_IN)));
        field[k] = next < -1.4 ? -1.4 : next > 1.4 ? 1.4 : next;
      }
    }
  };

  // Melt: spread each mark into its neighbours and let it slowly flatten.
  const melt = elapsed => {
    const decay = Math.pow(MELT, elapsed / (1000 / 60));
    let energy = 0;
    for (let y = 1; y < rows - 1; y++) {
      for (let x = 1; x < cols - 1; x++) {
        const k = y * cols + x;
        const lap = field[k - 1] + field[k + 1] + field[k - cols] + field[k + cols] - 4 * field[k];
        const next = (field[k] + lap * SPREAD_RATE) * decay;
        scratch[k] = next;
        const a = next < 0 ? -next : next;
        if (a > energy) energy = a;
      }
    }
    const swap = field;
    field = scratch;
    scratch = swap;
    return energy;
  };

  const pointer = { x: 0, y: 0, inside: false, lastMove: 0, vx: 0, vy: 0, drawX: 0, drawY: 0 };
  const state = { x: 0, y: 0, angle: 0, speed: 0, strength: 0 };
  let running = false;
  let filterOn = false;
  let uploading = false;
  let frameId = 0;
  let lastFrame = 0;
  let generation = 0;
  let slowFrames = 0;
  let interval = 1000 / 30;
  let scrollingUntil = 0;
  let mapUrl = null;

  const filterOff = () => {
    glass.style.backdropFilter = "none";
    filterOn = false;
  };

  // The map goes to the filter as a short-lived blob URL. A data: URL per frame left every decoded
  // frame in the image cache, so memory grew until the tab slowed down and reloaded.
  const stop = () => {
    running = false;
    cancelAnimationFrame(frameId);
    frameId = 0;
    lastFrame = 0;
    generation++;
    field.fill(0);
    scratch.fill(0);
    state.strength = state.speed = 0;
    pointer.inside = false;
    pointer.vx = pointer.vy = 0;
    filterOff();
    feImage.removeAttribute("href");
    if (mapUrl) URL.revokeObjectURL(mapUrl);
    mapUrl = null;
  };

  const upload = () => {
    // Never queue encodes: the next frame will use the latest field.
    if (uploading) return;
    const version = generation;
    ctx.putImageData(image, 0, 0);
    uploading = true;
    mapCanvas.toBlob(blob => {
      if (!blob || version !== generation || !running || calm() || document.hidden) {
        uploading = false;
        return;
      }
      const url = URL.createObjectURL(blob);
      const preload = new Image();
      preload.onload = () => {
        uploading = false;
        if (version !== generation || !running || calm() || document.hidden) {
          URL.revokeObjectURL(url);
          return;
        }
        feImage.setAttribute("href", url);
        if (mapUrl) URL.revokeObjectURL(mapUrl);
        mapUrl = url;
        if (!filterOn) {
          glass.style.backdropFilter = "url(#melted-glass)";
          filterOn = true;
        }
      };
      preload.onerror = () => { uploading = false; URL.revokeObjectURL(url); };
      preload.src = url;
    });
  };

  const compose = (amp, stretch) => {
    render.set(field);
    if (amp > 0.001) {
      const halfL = LENGTH / 2 * stretch;
      const halfW = WIDTH / 2 * (1 - (stretch - 1) * 0.25);
      const reach = FINGER * halfL;
      const cos = Math.cos(state.angle);
      const sin = Math.sin(state.angle);
      const cx = state.x - cos * reach;
      const cy = state.y - sin * reach;
      const box = Math.ceil(halfL / CELL) + 1;
      const gx = Math.round(cx / CELL);
      const gy = Math.round(cy / CELL);
      for (let j = -box; j <= box; j++) {
        const y = gy + j;
        if (y < 0 || y >= rows) continue;
        for (let i = -box; i <= box; i++) {
          const x = gx + i;
          if (x < 0 || x >= cols) continue;
          const dx = x * CELL - cx;
          const dy = y * CELL - cy;
          const u = (dx * cos + dy * sin) / halfL;
          const v = (-dx * sin + dy * cos) / halfW;
          if (u * u + v * v >= 1) continue;
          render[y * cols + x] += amp * surface(u, v);
        }
      }
    }
    const data = image.data;
    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < cols; x++) {
        const k = y * cols + x;
        const gxv = x > 0 && x < cols - 1 ? (render[k + 1] - render[k - 1]) * GAIN : 0;
        const gyv = y > 0 && y < rows - 1 ? (render[k + cols] - render[k - cols]) * GAIN : 0;
        const o = k * 4;
        data[o] = 128 + (gxv < -127 ? -127 : gxv > 127 ? 127 : gxv);
        data[o + 1] = 128 + (gyv < -127 ? -127 : gyv > 127 ? 127 : gyv);
        data[o + 2] = 128;
        data[o + 3] = 255;
      }
    }
    upload();
  };

  const frame = now => {
    frameId = 0;
    if (calm() || document.hidden || now - pointer.lastMove > 900 || now < scrollingUntil) {
      stop();
      return;
    }
    const elapsed = lastFrame ? now - lastFrame : interval;
    if (elapsed < interval - 1 || uploading) {
      frameId = requestAnimationFrame(frame);
      return;
    }
    lastFrame = now;
    const started = performance.now();
    const moving = pointer.inside && now - pointer.lastMove < 70;
    if (!moving) {
      pointer.vx *= 0.85;
      pointer.vy *= 0.85;
    }
    const target = moving ? 1 : 0;
    state.strength += (target - state.strength) * (target > state.strength ? 0.22 : 0.05);
    state.x += (pointer.x - state.x) * 0.35;
    state.y += (pointer.y - state.y) * 0.35;
    const velocity = Math.hypot(pointer.vx, pointer.vy);
    state.speed += (Math.min(velocity, 40) - state.speed) * 0.15;
    if (velocity > 0.6) {
      let delta = Math.atan2(pointer.vy, pointer.vx) - state.angle;
      while (delta > Math.PI) delta -= Math.PI * 2;
      while (delta < -Math.PI) delta += Math.PI * 2;
      state.angle += delta * 0.18;
    }

    if (moving) {
      const dx = state.x - pointer.drawX;
      const dy = state.y - pointer.drawY;
      const distance = Math.hypot(dx, dy);
      const steps = Math.min(12, Math.floor(distance / STAMP_STEP));
      for (let s = 1; s <= steps; s++) stamp(pointer.drawX + dx * s / steps, pointer.drawY + dy * s / steps, 1);
      if (steps) {
        pointer.drawX = state.x;
        pointer.drawY = state.y;
      }
    }
    const energy = melt(elapsed);
    const stretch = 1 + Math.min(state.speed / 40, 1) * 0.35;
    const amp = state.strength * (1 + state.speed * 0.012);
    compose(amp, stretch);

    // A sustained miss of the budget first reduces cadence, then keeps the static CRT.
    if (elapsed > interval * 1.8 || performance.now() - started > 12) slowFrames++;
    else slowFrames = Math.max(0, slowFrames - 1);
    if (slowFrames >= 8) {
      slowFrames = 0;
      if (interval < 50) interval = 50;
      else { root.classList.add("cs-lite"); stop(); return; }
    }
    if (!moving && state.strength < 0.002 && energy < 0.004) { stop(); return; }
    frameId = requestAnimationFrame(frame);
  };

  const wake = () => {
    if (running || calm() || document.hidden || performance.now() < scrollingUntil) return;
    running = true;
    frameId = requestAnimationFrame(frame);
  };

  resize();
  window.addEventListener("resize", () => {
    stop();
    if (oversized()) { root.classList.add("cs-lite"); return; }
    resize();
  });
  window.addEventListener("scroll", () => {
    scrollingUntil = performance.now() + 180;
    stop();
  }, { passive: true });
  document.addEventListener("visibilitychange", () => { if (document.hidden) stop(); });
  window.addEventListener("pagehide", stop);
  new MutationObserver(() => { if (calm()) stop(); })
    .observe(root, { attributes: true, attributeFilter: ["class"] });

  window.addEventListener("pointermove", event => {
    if (calm() || document.hidden || performance.now() < scrollingUntil) return;
    if (event.pointerType && event.pointerType !== "mouse" && event.pointerType !== "pen") return;
    const x = event.clientX;
    const y = event.clientY;
    if (!pointer.inside) {
      state.x = pointer.x = pointer.drawX = x;
      state.y = pointer.y = pointer.drawY = y;
    }
    pointer.vx = pointer.vx * 0.6 + (x - pointer.x) * 0.4;
    pointer.vy = pointer.vy * 0.6 + (y - pointer.y) * 0.4;
    pointer.x = x;
    pointer.y = y;
    pointer.inside = true;
    pointer.lastMove = performance.now();
    wake();
  }, { passive: true });

  root.addEventListener("mouseleave", stop);
})();
</script>`;
}

function fragmentForwardingScript(): string {
  return `<script>
(() => {
  const isAndroid = /Android/i.test(navigator.userAgent);
  const isIOS = !isAndroid && (/iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1));
  document.documentElement.classList.toggle("is-android", isAndroid);
  document.documentElement.classList.toggle("is-ios", isIOS);
  const appMeta = document.querySelector('meta[name="cryptoscreen-app-url"]');
  const webMeta = document.querySelector('meta[name="cryptoscreen-web-url"]');
  if (!appMeta || !webMeta) return;
  const appURL = new URL(appMeta.content);
  const webURL = new URL(webMeta.content);
  const currentURL = new URL(window.location.href);
  const clipPage = currentURL.origin === appURL.origin && currentURL.searchParams.get("clip") === "1";
  // The secret stays in the fragment, including while crossing our two hosts.
  appURL.hash = currentURL.hash;
  webURL.hash = currentURL.hash;
  // A real tap from www to the associated apex domain can open existing app versions.
  // Never synthesize a click or redirect again from the explicit App Clip card page.
  if (isIOS && currentURL.origin === appURL.origin && webURL.origin !== appURL.origin && !clipPage) {
    window.location.replace(webURL.href);
    return;
  }
  const banner = document.querySelector('meta[name="apple-itunes-app"]');
  if (banner) banner.content = banner.content.replace(/app-argument=[^,]*/, "app-argument=" + appURL.href);
  const forwardFragment = () => {
    document.querySelectorAll("[data-message-link]").forEach((link) => {
      const destination = new URL(link.href);
      destination.hash = window.location.hash;
      link.href = destination.href;
    });
  };
  window.addEventListener("DOMContentLoaded", forwardFragment);
  window.addEventListener("hashchange", forwardFragment);
})();
</script>`;
}

function messageReaderScript(): string {
  return `<script>
(() => {
  const messageID = document.querySelector("[data-message-id]")?.getAttribute("data-message-id") || "";
  const appActions = document.querySelector("[data-app-actions]");
  const openState = document.querySelector("[data-open-state]");
  const reader = document.querySelector("[data-browser-reader]");
  const pinInput = document.querySelector("[data-pin]");
  const readerStatus = document.querySelector("[data-reader-status]");
  const output = document.querySelector("[data-message-output]");
  const plaintextOutput = document.querySelector("[data-plaintext]");
  const attachmentOutput = document.querySelector("[data-attachment]");

  const isIOS = document.documentElement.classList.contains("is-ios");
  let opening = false;
  let consumed = false;
  let browserAllowed = false;
  let attachmentURL = null;
  let pageClosed = false;
  const setStatus = (message) => {
    if (readerStatus) readerStatus.textContent = message;
  };
  const setOpenState = (message) => {
    if (openState) openState.textContent = message;
  };

  if (appActions) appActions.hidden = !isIOS;

  const base64UrlToBytes = (value) => {
    const normalized = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  };

  const bytesToBase64Url = (bytes) => {
    let binary = "";
    bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
    return btoa(binary).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/g, "");
  };

  const concatBytes = (...parts) => {
    const total = parts.reduce((sum, part) => sum + part.byteLength, 0);
    const combined = new Uint8Array(total);
    let offset = 0;
    parts.forEach((part) => {
      combined.set(part, offset);
      offset += part.byteLength;
    });
    return combined;
  };

  const fragmentSecret = () => {
    const fragment = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    const secret = fragment.get("s");
    if (!secret) throw new Error("missing_secret");
    if (!/^[A-Za-z0-9_-]+={0,2}$/.test(secret)) throw new Error("invalid_secret");
    const bytes = base64UrlToBytes(secret);
    if (bytes.byteLength < 32) throw new Error("invalid_secret");
    return bytes;
  };

  const deriveBits = async (linkSecret, pin, salt, info) => {
    const pinBytes = new TextEncoder().encode(pin);
    const inputKeyMaterial = concatBytes(linkSecret, pinBytes);
    const baseKey = await crypto.subtle.importKey("raw", inputKeyMaterial, "HKDF", false, ["deriveBits"]);
    return new Uint8Array(await crypto.subtle.deriveBits({
      name: "HKDF",
      hash: "SHA-256",
      salt,
      info: new TextEncoder().encode(info)
    }, baseKey, 256));
  };

  const makePinProof = async (linkSecret, pin) => {
    const verifierKeyBytes = await deriveBits(
      linkSecret,
      pin,
      new TextEncoder().encode("cryptoscreen pin proof salt v1"),
      "cryptoscreen pin verifier v1"
    );
    const verifierKey = await crypto.subtle.importKey("raw", verifierKeyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const signature = await crypto.subtle.sign("HMAC", verifierKey, new TextEncoder().encode("cryptoscreen pin proof"));
    return new Uint8Array(signature);
  };

  const deriveContentKey = async (linkSecret, pin, salt) => {
    const keyBytes = await deriveBits(linkSecret, pin, salt, "cryptoscreen content key v1");
    return await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  };

  const decryptAesGcm = async (key, nonce, ciphertext, tag) => {
    const combined = concatBytes(ciphertext, tag);
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, key, combined));
  };

  const decryptCombinedAesGcm = async (key, combined) => {
    if (combined.byteLength <= 28) throw new Error("invalid_payload");
    const nonce = combined.slice(0, 12);
    const ciphertextWithTag = combined.slice(12);
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, key, ciphertextWithTag));
  };

  const showReader = () => {
    if (!reader || consumed || pageClosed) return;
    try {
      fragmentSecret();
    } catch {
      setStatus("This link is incomplete. Open the full link from the sender, including everything after #s=.");
      return;
    }
    if (!window.crypto || !crypto.subtle) {
      setStatus("This browser cannot use Web Crypto. Open the message in cryptoscreen.");
      return;
    }
    reader.hidden = false;
    setStatus(isIOS ? "The app is the safer option. Browser reading is available because the sender allowed it." : "Browser reading is available because the sender allowed it.");
  };

  const loadStatus = async () => {
    if (opening || consumed || pageClosed) return;
    try {
      const response = await fetch("/api/messages/" + encodeURIComponent(messageID) + "/status", {
        cache: "no-store",
        headers: { Accept: "application/json" }
      });
      if (!response.ok) throw new Error("status_failed");
      const data = await response.json();
      if (opening || consumed || pageClosed) return;
      browserAllowed = false;
      if (reader) reader.hidden = true;
      if (data.status !== "active") {
        if (appActions) appActions.hidden = true;
        setOpenState("This message is " + data.status + ".");
        setStatus("It cannot be opened from the browser or app anymore.");
        return;
      }
      if (data.readPolicy === "web_allowed") {
        browserAllowed = true;
        setOpenState(isIOS ? "Open in cryptoscreen, or read here if the app is not available." : "This message can be read in this browser.");
        showReader();
        return;
      }
      setOpenState("This message is app only.");
      setStatus(isIOS ? "Tap Open in app, or use the App Clip if the app is not installed." : "The sender restricted this message to iPhone. Ask them to create a new message with App or web selected to read it on this device.");
    } catch {
      if (opening || consumed || pageClosed) return;
      setOpenState("Could not check this message.");
      setStatus("Check your connection and reload this page." + (isIOS ? " You can also open it in cryptoscreen." : ""));
    }
  };

  const openAttachment = async (attachment, contentKey) => {
    if (!attachment || !attachmentOutput) return;
    const keyPayload = base64UrlToBytes(attachment.encryptedFileKey);
    const imageKeyBytes = await decryptCombinedAesGcm(contentKey, keyPayload);
    const imageKey = await crypto.subtle.importKey("raw", imageKeyBytes, "AES-GCM", false, ["decrypt"]);
    const response = await fetch(attachment.downloadPath, { cache: "no-store" });
    if (!response.ok) throw new Error("attachment_unavailable");
    const encryptedImage = new Uint8Array(await response.arrayBuffer());
    const imageBytes = await decryptCombinedAesGcm(imageKey, encryptedImage);
    if (pageClosed) return;
    const blob = new Blob([imageBytes], { type: attachment.contentType || "application/octet-stream" });
    attachmentURL = URL.createObjectURL(blob);
    attachmentOutput.src = attachmentURL;
    attachmentOutput.onerror = () => {
      setStatus("The text is open, but this browser cannot display the attached image format. The message has already been consumed.");
    };
    attachmentOutput.hidden = false;
  };

  const clearMessage = () => {
    pageClosed = true;
    if (plaintextOutput) plaintextOutput.textContent = "";
    if (attachmentOutput) {
      attachmentOutput.removeAttribute("src");
      attachmentOutput.hidden = true;
    }
    if (attachmentURL) URL.revokeObjectURL(attachmentURL);
    attachmentURL = null;
    if (pinInput) pinInput.value = "";
    if (output) output.hidden = true;
    if (consumed) setStatus("Message cleared. It cannot be opened again.");
  };
  document.querySelector("[data-close-message]")?.addEventListener("click", clearMessage);
  window.addEventListener("pagehide", clearMessage);
  window.addEventListener("pageshow", (event) => {
    if (event.persisted && !consumed) {
      pageClosed = false;
      loadStatus();
    }
  });
  window.addEventListener("hashchange", () => {
    if (!opening && !consumed && browserAllowed) showReader();
  });

  if (reader) {
    reader.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (opening || consumed || !browserAllowed || pageClosed) return;
      const pin = String(pinInput?.value || "").replace(/\\D/g, "").slice(0, 6);
      if (pinInput) pinInput.value = pin;
      if (pin.length !== 6) {
        setStatus("Enter the six-digit PIN from the sender.");
        return;
      }
      try {
        opening = true;
        reader.querySelector("button")?.setAttribute("disabled", "disabled");
        setStatus("Opening...");
        const linkSecret = fragmentSecret();
        const pinProof = await makePinProof(linkSecret, pin);
        const response = await fetch("/api/messages/" + encodeURIComponent(messageID) + "/consume", {
          method: "POST",
          headers: { "Content-Type": "application/json", Accept: "application/json" },
          body: JSON.stringify({
            pinProof: bytesToBase64Url(pinProof),
            clientOptIn: false,
            readerClient: "web"
          })
        });
        const data = await response.json().catch(() => ({}));
        if (!response.ok) {
          if (data?.error?.code === "app_only_message") {
            browserAllowed = false;
            reader.hidden = true;
            setStatus("This message can only be opened in cryptoscreen or the App Clip.");
            return;
          }
          throw new Error(data?.error?.message || "open_failed");
        }
        if (data.status === "wrong_pin") {
          setStatus("Wrong PIN. " + (data.remainingAttempts || 0) + " attempts remaining.");
          return;
        }
        if (data.status !== "opened") {
          browserAllowed = false;
          reader.hidden = true;
          if (appActions) appActions.hidden = true;
          setStatus("This message is " + data.status + ".");
          return;
        }
        consumed = true;
        reader.hidden = true;
        if (appActions) appActions.hidden = true;
        if (pinInput) pinInput.value = "";
        setOpenState("Message opened.");
        const salt = base64UrlToBytes(data.salt);
        const contentKey = await deriveContentKey(linkSecret, pin, salt);
        const plaintextBytes = await decryptAesGcm(
          contentKey,
          base64UrlToBytes(data.nonce),
          base64UrlToBytes(data.ciphertext),
          base64UrlToBytes(data.tag)
        );
        if (pageClosed) return;
        if (plaintextOutput) plaintextOutput.textContent = new TextDecoder().decode(plaintextBytes);
        if (output) output.hidden = false;
        reader.hidden = true;
        setStatus("Read your message before closing this page. It cannot be opened again.");
        try {
          await openAttachment(data.attachment, contentKey);
        } catch {
          if (!pageClosed) setStatus("The text is open, but the attachment could not be loaded. Keep this page open to finish reading the text.");
        }
      } catch {
        if (!pageClosed) setStatus(consumed
          ? "The message was consumed, but this browser could not decrypt it. Ask the sender to send a new message."
          : "The message could not be opened. Check your connection and that you have the complete link.");
      } finally {
        opening = false;
        reader.querySelector("button")?.removeAttribute("disabled");
      }
    });
  }

  loadStatus();
})();
</script>`;
}

function smartAppBannerMeta(env: Env, links: MessagePageLinks): string {
  const vars = env as unknown as Record<string, string | undefined>;
  const appClipBundleID = vars.APP_CLIP_BUNDLE_ID;
  const parts = [`app-id=${appleAppStoreId(env)}`, `app-argument=${links.appUrl}`];
  if (appClipBundleID && links.appClipBanner) {
    parts.push(`app-clip-bundle-id=${appClipBundleID}`);
    if (links.clipPage) parts.push("app-clip-display=card");
  }

  return `<meta name="apple-itunes-app" content="${escapeAttribute(parts.join(", "))}">`;
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

function appleAppStoreId(env: Env): string {
  const vars = env as unknown as Record<string, string | undefined>;
  const value = vars.APPLE_APP_ID ?? "6779173642";
  return /^[0-9]+$/.test(value) ? value : "6779173642";
}

function xHandleFromUrl(value: string): string {
  try {
    const url = new URL(value);
    const handle = url.pathname.split("/").filter(Boolean)[0] ?? "DomenicoDD";
    return /^@?[A-Za-z0-9_]{1,15}$/.test(handle) ? `@${handle.replace(/^@/, "")}` : "@DomenicoDD";
  } catch {
    return "@DomenicoDD";
  }
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
