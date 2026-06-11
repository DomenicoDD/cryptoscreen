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
- Plaintext is not selectable, copied, logged, cached, or written to disk by the app.
- The App Clip can consume a message without installing the full app.

## Non-Goals

- Preventing someone from photographing the screen with another device.
- Reliably blocking every normal iOS screenshot before capture. Public APIs notify the app after a screenshot is taken.
- Protecting plaintext after the recipient has legitimately read it.
- Recovering a deleted or expired message.

## Actors

- Sender: creates plaintext and PIN.
- Recipient: receives the link and PIN through separate channels.
- API: validates online attempts and controls deletion.
- Neon: stores ciphertext and attempt metadata.
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

The online `pin_proof` intentionally does not depend on the message encryption salt. The recipient must be able to compute the proof before the API returns the encrypted payload and salt. The content key still uses the per-message salt, and the server still never receives the link secret or plaintext.

Production should not store the raw `pin_proof` directly. The API should store:

```text
stored_pin_verifier = HMAC(SERVER_PIN_PEPPER, pin_proof)
```

That prevents a database-only compromise from becoming an offline brute-force oracle. The API recomputes the same HMAC when a recipient submits a proof.

## Neon Schema

The checked-in migration is [database/schema.sql](../database/schema.sql). It is the source of truth for the current Neon schema.

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
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index sealed_messages_expires_at_idx
  on cryptoscreen.sealed_messages (expires_at);
```

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

Creates a sealed message. Request contains ciphertext, nonce, tag, salt, TTL, and the raw client PIN proof. The Worker stores only `HMAC(SERVER_PIN_PEPPER, pin_proof)`. Response contains the message id.

The production TTL limit is 30 days. Clients may request a shorter TTL, but unopened links cannot be retained longer than 30 days.

```text
POST /api/messages/{id}/consume
```

Consumes one attempt. Request contains the client-generated PIN proof. Response is one of:

- `opened`: returns encrypted payload and deletes the row.
- `wrong_pin`: returns remaining attempt count.
- `destroyed`: message deleted after third wrong attempt.
- `expired`: message deleted because TTL passed.
- `unavailable`: no row exists.

The Worker also serves:

- `GET /privacy`
- `GET /support`
- `GET /m/<message-id>`
- `GET /.well-known/apple-app-site-association`

The Apple association file currently declares the parent app identifier and App Clip bundle identifier for `cryptoscreen.app`.

## App Clip Behavior

The App Clip should:

1. Receive the invocation URL.
2. Parse `message_id` and `link_secret`.
3. Ask for the six-digit PIN before fetching message contents.
4. Derive the PIN proof locally.
5. Call `POST /messages/{id}/consume`.
6. On `opened`, derive `content_key` locally and decrypt.
7. Render plaintext only in the protected reader.
8. Clear plaintext on close, background, capture, or app termination.

The full app should handle the same URL format. If the full app is installed, iOS may open it instead of the App Clip.

## Copy and Capture Controls

The app should:

- Render plaintext with non-editable SwiftUI `Text`, not `TextEditor`, `UITextView`, or WebView.
- Keep `.textSelection(.disabled)` around the reader.
- Avoid plaintext accessibility labels.
- Avoid share sheets or clipboard actions for plaintext.
- Avoid logging plaintext, PINs, proofs, or links.
- Black out the interface when screen recording or mirroring is active.
- Black out app switcher snapshots when the scene leaves active state.
- React to screenshot notification by redacting immediately after detection.

Screenshot prevention is best-effort. iOS does not provide a supported way to guarantee that every normal screenshot is black before capture.

## Data Retention

Live database:

- Correct PIN: row deleted immediately.
- Third wrong PIN: row deleted immediately.
- Expired row: deleted by scheduled cleanup.

Backups and restore history:

- Neon point-in-time restore can preserve historical encrypted rows during the restore window.
- This is acceptable only because the server stores ciphertext and verifier material, not plaintext or decryption keys.
- Use short restore windows for production if the product promise requires tighter retention.

Client:

- Plaintext is held in memory only while the reader is open.
- Plaintext should not be persisted to disk.
- Crash and analytics tooling must not capture plaintext, PINs, proofs, or full links.

## Export Compliance

This project uses standard Apple CryptoKit primitives for encryption. Before shipping this feature broadly, App Store Connect export-compliance answers must be reviewed. The expected category is standard/exempt encryption, but the app should not continue to claim "no encryption" after this feature is enabled.
