# cryptoscreen Security Architecture

This document describes the security structure for cryptoscreen. The iOS app performs client-side sealing and opening. A Cloudflare Worker API stores ciphertext in Neon Postgres and owns the online attempt/deletion policy.

## Goals

- The server never stores or receives plaintext.
- The server never stores or receives the decryption key.
- A message can be opened once.
- The recipient gets three online PIN attempts.
- A correct PIN returns ciphertext and deletes the database row.
- The third wrong PIN deletes the database row.
- Unopened links expire and are deleted after 30 days.
- Service-owned retained demo/review rows may be reused and are not for user messages.
- Pro image attachments are encrypted on device before upload and stored only as ciphertext in private R2 storage.
- Plaintext is not selectable, copied, logged, cached, or written to disk by the app.
- The App Clip can consume a message without installing the full app.

## Non-Goals

- Preventing someone from photographing the screen with another device.
- Reliably blocking every normal iOS screenshot before capture. Public APIs notify the app after a screenshot is taken.
- Protecting plaintext after the recipient has legitimately read it.
- Cryptographically preventing a recipient from saving or photographing content after it is displayed.
- Proving that uploaded attachment ciphertext is actually an image. The server cannot inspect encrypted content.
- Recovering a deleted or expired message.

## Actors

- Sender: creates plaintext and PIN.
- Recipient: receives the link and PIN through separate channels.
- API: validates online attempts and controls deletion.
- Neon: stores ciphertext and attempt metadata.
- R2: stores encrypted image attachment objects only.
- Cloudflare Worker: hosts the public website, Apple association file, and API boundary.
- App Clip or full app: decrypts locally after the API returns ciphertext.

## High-Level Flow

{here image that shows the sender-side seal and upload handshake}

{here image that shows the recipient App Clip invocation and PIN verification handshake}

{here image that shows the third wrong PIN attempt deleting the message}

{here image that shows the server boundary: plaintext and key stay client-side, Neon stores ciphertext only}

## Message Link

The shared URL carries the message id in the path and the high-entropy secret in the fragment:

```text
https://cryptoscreen.app/m/<message-id>#s=<link-secret>
```

The fragment is intentional. Browsers and servers normally do not receive URL fragments in HTTP requests. The app or App Clip can still read the fragment from the invocation URL.

App Store Connect review links may use `?s=<link-secret>` on a retained service-owned demo message because App Clip invocation testing is more reliable with a query parameter than a URL fragment. This exception is only for demo/review rows and should not be used for user-created messages.

The PIN is not placed in the link. The sender shares it separately.

## Key Derivation

The client generates:

- `message_id`: random UUID
- `link_secret`: 32 random bytes, encoded in the URL fragment
- `salt`: random bytes stored with the message
- `pin`: six digits entered by the sender

The client derives:

- `content_key = HKDF(link_secret + pin, salt, "cryptoscreen content key v1")`
- `pin_proof_key = HKDF(link_secret + pin, "cryptoscreen pin proof salt v1", "cryptoscreen pin verifier v1")`
- `pin_proof = HMAC(pin_proof_key, "cryptoscreen pin proof")`

The app encrypts plaintext with `content_key`, then uploads only ciphertext and proof material.

For Pro image attachments, the app uses envelope encryption:

```text
image_key = random 32 bytes
image_ciphertext = AES-GCM(image_key, normalized_image_bytes)
encrypted_image_key = AES-GCM(content_key, image_key)
```

The server stores `image_ciphertext` in private R2 storage and stores `encrypted_image_key` in Neon metadata. The server never receives the image plaintext or raw `image_key`.

The online `pin_proof` intentionally does not depend on the message encryption salt. The recipient must be able to compute the proof before the API returns the encrypted payload and salt. The content key still uses the per-message salt, and the server still never receives the link secret or plaintext.

Production should not store the raw `pin_proof` directly. The API should store:

```text
stored_pin_verifier = HMAC(SERVER_PIN_PEPPER, pin_proof)
```

That prevents a database-only compromise from becoming an offline brute-force oracle. The API recomputes the same HMAC when a recipient submits a proof.

## Neon Schema

The checked-in migration is [database/schema.sql](../database/schema.sql). It is the source of truth for the current Neon schema.

For a simpler walkthrough of the schema, R2 storage, and why this is safe to publish in an open-source repo, read [DATABASE_AND_STORAGE.md](DATABASE_AND_STORAGE.md).

Recommended initial table shape:

```sql
create table cryptoscreen.sealed_messages (
  id uuid primary key,
  ciphertext bytea not null,
  nonce bytea not null,
  tag bytea not null,
  salt bytea not null,
  pin_verifier bytea not null,
  failed_attempts smallint not null default 0,
  max_attempts smallint not null default 3,
  read_policy cryptoscreen.sealed_message_read_policy not null default 'app_only',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index sealed_messages_expires_at_idx
  on cryptoscreen.sealed_messages (expires_at);

create table cryptoscreen.message_stats (
  id boolean primary key default true,
  shared_messages bigint not null default 0,
  updated_at timestamptz not null default now()
);
```

`message_stats.shared_messages` is an aggregate public-site counter. It is cumulative and does not contain plaintext, link secrets, sender identifiers, or recipient identifiers.

The schema also includes attachment tables for V2 Pro image support:

- `sealed_message_attachments`: one encrypted image metadata row per message.
- `sealed_message_read_sessions`: short-lived one-time download sessions created after a successful PIN consume.
- `sealed_message_read_session_events`: optional best-effort reader events such as screenshot detection.
- `sealed_message_delivery_audit`: minimal delivery-status metadata for sender history, retained only for a short cleanup window.

Attachment rows contain R2 object keys, ciphertext byte counts, declared content type, and encrypted image keys. They do not contain image plaintext or raw image keys.

Use a cleanup job to delete expired rows:

```sql
delete from cryptoscreen.sealed_messages
where expires_at <= now();
```

Neon supports point-in-time restore within a restore window. Deleted rows may exist in restore history for that window, so the design assumes restored data is still encrypted and unusable without the link secret and PIN.

## Atomic Consume Operation

The API must perform attempt validation and deletion atomically. A Postgres function is a good fit because it avoids multi-round-trip race conditions:

```sql
create type sealed_message_consume_status as enum (
  'opened',
  'wrong_pin',
  'destroyed',
  'expired',
  'unavailable'
);

create or replace function consume_sealed_message(
  p_id uuid,
  p_pin_verifier bytea
)
returns table (
  status sealed_message_consume_status,
  remaining_attempts int,
  ciphertext bytea,
  nonce bytea,
  tag bytea,
  salt bytea
)
language plpgsql
as $$
declare
  message sealed_messages%rowtype;
begin
  select *
  into message
  from sealed_messages
  where id = p_id
  for update;

  if not found then
    status := 'unavailable';
    remaining_attempts := 0;
    return next;
    return;
  end if;

  if message.expires_at <= now() then
    delete from sealed_messages where id = p_id;
    status := 'expired';
    remaining_attempts := 0;
    return next;
    return;
  end if;

  if message.pin_verifier = p_pin_verifier then
    delete from sealed_messages where id = p_id;
    status := 'opened';
    remaining_attempts := message.max_attempts - message.failed_attempts;
    ciphertext := message.ciphertext;
    nonce := message.nonce;
    tag := message.tag;
    salt := message.salt;
    return next;
    return;
  end if;

  if message.failed_attempts + 1 >= message.max_attempts then
    delete from sealed_messages where id = p_id;
    status := 'destroyed';
    remaining_attempts := 0;
    return next;
    return;
  end if;

  update sealed_messages
  set failed_attempts = failed_attempts + 1
  where id = p_id
  returning failed_attempts, max_attempts
  into message.failed_attempts, message.max_attempts;

  status := 'wrong_pin';
  remaining_attempts := message.max_attempts - message.failed_attempts;
  return next;
end;
$$;
```

Production should run this with least-privilege database credentials through the API only. The iOS app and App Clip must not hold Neon credentials.

## API Shape

Minimum endpoints:

```text
POST /api/messages
```

Creates a sealed message. Request contains ciphertext, nonce, tag, salt, TTL, read policy, and the raw client PIN proof. The Worker stores only `HMAC(SERVER_PIN_PEPPER, pin_proof)`. Response contains the message id.

The production TTL limit is 30 days. Clients may request a shorter TTL, but unopened user links cannot be retained longer than 30 days. Service-owned retained demo/review rows are excluded from expiry cleanup and must not contain private user content.

`read_policy` is `app_only` by default. If the sender chooses `web_allowed`, the hosted `/m/<id>` page may offer browser-side decryption. App-only messages should be opened in the iOS app or App Clip; the public web reader refuses them.

```text
POST /api/messages/{id}/consume
```

Consumes one attempt. Request contains the client-generated PIN proof. Response is one of:

- `opened`: returns encrypted payload and deletes the row.
- `wrong_pin`: returns remaining attempt count.
- `destroyed`: message deleted after third wrong attempt.
- `expired`: message deleted because TTL passed.
- `unavailable`: no row exists.

For service-owned retained demo/review rows, `opened` returns encrypted payload without deleting the row, and wrong PIN attempts do not mutate the row. The response includes a `retained` boolean so clients can avoid displaying normal deletion copy for the demo path.

One-time links necessarily expose some passive delivery state: when a link stops opening, someone with the link can infer that the row was opened, expired, destroyed after wrong PIN attempts, or manually expired by the sender. This is separate from optional screenshot event reporting and is inherent to enforcing one-time reads.

```text
PUT /api/messages/{id}/attachment
```

Uploads one encrypted image attachment for an active normal message. The request body is `application/octet-stream` ciphertext. Headers contain untrusted metadata such as declared image content type and the encrypted image key. The Worker stores ciphertext in the private `ATTACHMENTS` R2 bucket and stores metadata in Neon.

```text
GET /api/read-sessions/{id}/attachment
```

Downloads encrypted attachment bytes through a short-lived read session. The Worker marks the session consumed and deletes the R2 object after returning the ciphertext bytes.

```text
POST /api/read-sessions/{id}/events
```

Stores opt-in best-effort reader events such as screenshot detection. Events must never contain message plaintext, image plaintext, PINs, proofs, or full links. The official app keeps reciprocal interaction status sharing off by default in Privacy settings.

The Worker also serves:

- `GET /privacy`
- `GET /support`
- `GET /m/<message-id>`
- `GET /.well-known/apple-app-site-association`
- `POST /api/feedback`

The Apple association file currently declares the parent app identifier and App Clip bundle identifier for `cryptoscreen.app`.

`POST /api/feedback` accepts onboarding sentiment feedback for low ratings. The app sends rating, trimmed feedback text, app version/build, platform/device info, and timestamp. The Worker validates the payload, limits feedback text to 2,000 characters, and sends email server-side through the configured `FEEDBACK_EMAIL_SENDER` binding so mail-provider credentials are never shipped in the app.

See [V2_PRO_IMAGES.md](V2_PRO_IMAGES.md) for the Pro image attachment architecture and payment sequencing.

## App Clip Behavior

The App Clip should:

1. Receive the invocation URL.
2. Parse `message_id` and `link_secret`.
3. Ask for the six-digit PIN before fetching message contents.
4. Derive the PIN proof locally.
5. Call `POST /messages/{id}/consume`.
6. On `opened`, derive `content_key` locally and decrypt.
7. If the response includes an attachment read session, download encrypted image bytes through the Worker and decrypt locally.
8. Render plaintext and any image only in the protected reader.
9. Clear plaintext and image bytes on close, background, capture, or app termination.

The full app should handle the same URL format. If the full app is installed, iOS may open it instead of the App Clip.

## Copy and Capture Controls

The app should:

- Render plaintext with non-editable SwiftUI `Text`, not `TextEditor`, `UITextView`, or WebView.
- Keep `.textSelection(.disabled)` around the reader.
- Avoid plaintext accessibility labels.
- Avoid share sheets or clipboard actions for plaintext.
- Avoid save, share, copy, export, or open-in actions for decrypted image attachments.
- Avoid logging plaintext, PINs, proofs, or links.
- Black out the interface when screen recording or mirroring is active.
- Black out app switcher snapshots when the scene leaves active state.
- React to screenshot notification by redacting immediately after detection and destroying the visible reader session.
- Report screenshot events through the read-session event endpoint only when the reader has enabled interaction status sharing and a cooperative client has an active attachment read session.

Screenshot prevention is best-effort. iOS does not provide a supported way to guarantee that every normal screenshot is black before capture. Screenshot-triggered local destruction happens after iOS reports the screenshot. Interaction status sharing is opt-in and best-effort because modified open-source clients can omit events and external cameras cannot be detected.

## Data Retention

Live database:

- Correct PIN: row deleted immediately.
- Third wrong PIN: row deleted immediately.
- Expired row: deleted by scheduled cleanup.
- Attachment metadata: deleted with its normal message row or expired read session.
- Read session: expires after a short download window or is marked consumed after one download.
- Delivery-status metadata: deleted by scheduled cleanup after it has been inactive for about 30 days.

R2:

- Encrypted attachment objects are deleted after successful one-time download.
- Expired encrypted attachment objects are deleted by scheduled cleanup before database metadata is removed.
- Expired read-session object keys are also included in cleanup as a backstop, even if the read session was already marked consumed.

Backups and restore history:

- Neon point-in-time restore can preserve historical encrypted rows during the restore window.
- This is acceptable only because the server stores ciphertext and verifier material, not plaintext or decryption keys.
- Use short restore windows for production if the product promise requires tighter retention.

Client:

- Plaintext is held in memory only while the reader is open.
- Decrypted image bytes are held in memory only while the reader is open.
- Plaintext should not be persisted to disk.
- Decrypted image bytes should not be persisted to disk or exposed through save/share/export actions.
- Crash and analytics tooling must not capture plaintext, PINs, proofs, or full links.

## Export Compliance

This project uses standard Apple CryptoKit primitives for encryption. Before shipping this feature broadly, App Store Connect export-compliance answers must be reviewed. The expected category is standard/exempt encryption, but the app should not continue to claim "no encryption" after this feature is enabled.
