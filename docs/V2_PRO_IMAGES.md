# cryptoscreen V2 Pro Images

This document defines the first paid-feature architecture for cryptoscreen. The implementation should stay compatible with the open-source project while allowing the official hosted service to charge for server-backed features that create ongoing storage, request, and notification costs.

## Product Scope

V2 Pro adds one encrypted image attachment to a sealed message.

The free product remains useful:

- Create and open one-time text messages.
- Encrypt on device.
- Require the link secret and PIN.
- Delete normal messages after one successful read, the third wrong PIN, or expiry.
- Open received messages without an account or payment.

The Pro product adds server-backed features:

- One encrypted image per message.
- Larger payload allowance for image ciphertext.
- Custom expiry controls in a later milestone.
- More active sent messages in a later milestone.
- Screenshot detection events in a later milestone.
- Push notifications in a later milestone.

Opening a received message should remain free. The Pro gate belongs on the sender side and on official-service server limits.

## Open Source Model

cryptoscreen remains open source. The repository can include the app code, Worker code, schema, and feature gates. The official service at `cryptoscreen.app` can still enforce commercial limits because the enforcement happens server-side:

- The app may show or hide Pro controls, but the Worker must enforce official-service limits.
- A modified client cannot unlock storage on `cryptoscreen.app` without passing the official entitlement checks once payments are added.
- Self-hosted deployments can configure their own limits and can choose to enable Pro-style features without Apple payments.

The repository must not contain production secrets:

- App Store Server API keys.
- APNs keys.
- Cloudflare credentials.
- Neon credentials.
- R2 access credentials.
- Server HMAC secrets.

## Security Goals

- The service never receives image plaintext.
- The service never receives an image decryption key in plaintext.
- Images are encrypted before upload.
- R2 stores only ciphertext.
- The Worker mediates all R2 access; the bucket is not public.
- A normal image message can be opened once.
- The encrypted R2 object is deleted after successful download or expiry cleanup.
- The app does not expose save, share, copy, or open-in actions for decrypted images.
- The app redacts while screen recording or mirroring is detected.
- The app can report screenshot events after iOS reports them.

## Non-Goals

- Preventing someone from photographing the screen with another device.
- Preventing every screenshot before capture. Public iOS APIs report normal screenshots after capture.
- Preventing modified open-source clients from ignoring screenshot reporting.
- Proving that uploaded ciphertext is actually an image. The server cannot inspect plaintext.
- Supporting generic documents, PDFs, audio, video, archives, or arbitrary files.

## Supported Attachment Types

V2 should only support images selected through the official iOS app:

- JPEG
- PNG
- HEIC/HEIF when provided by iOS

The app should normalize selected images before encryption:

- Strip metadata, including EXIF and GPS.
- Optionally resize very large images.
- Encode to a bounded format and quality.
- Enforce the official maximum plaintext byte size before encryption.

The Worker treats the content type as untrusted metadata. It enforces size, count, retention, and entitlement limits, but it does not claim to verify image content.

## Cryptographic Format

V2 uses envelope encryption for the image:

```text
message_key = HKDF(link_secret + pin, message_salt, "cryptoscreen content key v1")
image_key = random 32 bytes

image_ciphertext = AES-GCM(image_key, normalized_image_bytes)
encrypted_image_key = AES-GCM(message_key, image_key)
```

Both `image_ciphertext` and `encrypted_image_key` are stored as combined AES-GCM payloads that include nonce, ciphertext, and tag. The server stores and transports those bytes, but it cannot decrypt them.

The recipient flow is:

```text
link_secret + pin + message_salt -> message_key
message_key + encrypted_image_key -> image_key
image_key + image_ciphertext -> normalized_image_bytes
```

## Backend Storage

Use a private Cloudflare R2 bucket bound to the Worker. The bucket should not be publicly exposed.

Object keys should be opaque and scoped under the message:

```text
attachments/<message-id>/<attachment-id>.bin
```

The database stores attachment metadata:

- Message id.
- Attachment id.
- R2 object key.
- Ciphertext byte count.
- Encrypted image key.
- Declared content type.
- Expiry time.

The R2 object is deleted when:

- The recipient successfully downloads the encrypted object through a read session.
- Expiry cleanup runs.
- An upload or finalize operation fails after writing the object.

In the current Worker implementation, successful attachment download is intentionally one-time. The Worker marks the read session consumed, reads the encrypted R2 object, deletes that R2 object, and then returns the encrypted bytes with `Cache-Control: no-store`. Scheduled cleanup also deletes expired read-session object keys as a storage backstop.

## API Shape

The first implementation can extend the existing message flow without introducing accounts:

```text
POST /api/messages
PUT  /api/messages/<message-id>/attachment
POST /api/messages/<message-id>/consume
GET  /api/read-sessions/<read-session-id>/attachment
POST /api/read-sessions/<read-session-id>/events
```

`POST /api/messages` creates the encrypted text row exactly as V1 does.

`PUT /api/messages/<message-id>/attachment` uploads one encrypted image object for an active message. Request headers carry metadata:

```text
content-type: application/octet-stream
x-cryptoscreen-attachment-type: image
x-cryptoscreen-attachment-content-type: image/jpeg
x-cryptoscreen-encrypted-file-key: <base64url combined AES-GCM payload>
```

The request body is the image ciphertext bytes.

`POST /api/messages/<message-id>/consume` still performs the online PIN attempt. If a normal message is opened and has an attachment, the Worker creates a short-lived read session and returns encrypted attachment metadata plus a download path. The normal message row is consumed before rendering, preserving one-time semantics.

`GET /api/read-sessions/<read-session-id>/attachment` returns the encrypted object bytes once, marks the session consumed, and deletes the R2 object. Responses must use `Cache-Control: no-store`.

`POST /api/read-sessions/<read-session-id>/events` records best-effort reader events such as screenshot detection. Events must not contain message plaintext or image plaintext.

## Screenshot Events

iOS can notify the app after a normal screenshot is taken. It can also report active screen capture states such as screen recording or mirroring. cryptoscreen should present this honestly:

- Screen recording and mirroring redaction is proactive while iOS reports capture.
- Normal screenshot detection is reactive after iOS reports the screenshot.
- The official app should immediately destroy the visible reader session after iOS reports a screenshot.
- Screenshot alerts are best-effort and require the official app or another cooperative client.

Event payloads should be generic:

```json
{
  "type": "screenshot",
  "timestamp": "2026-06-12T12:00:00Z"
}
```

Push notifications can be added later. Until then, screenshot events can be stored for future sender history.

## App Behavior

Sender:

- Select one image.
- Normalize and strip metadata locally.
- Encrypt image locally.
- Upload encrypted text first.
- Upload encrypted image ciphertext to the message.
- Share the same cryptoscreen link and PIN model.

Recipient:

- Enter link and PIN.
- The Worker consumes the online attempt.
- The app downloads encrypted image bytes through a read session.
- The app decrypts image bytes in memory.
- The app renders inside `CaptureShield`.
- The app does not provide save/share/export actions for the decrypted image.
- The app clears decrypted image data when the reader closes.

## Payment Milestone

Do not couple the initial image implementation to App Store Connect.

First, ship a feature-gated implementation that can run in development and self-hosted deployments. Then add:

- StoreKit 2 purchase and restore.
- App Store Server API verification on the Worker.
- Pseudonymous subscription rows keyed by a server-side HMAC of Apple transaction identifiers.
- Official-service quotas enforced by the Worker.

This keeps the cryptographic and storage flow testable before payment configuration is introduced.
