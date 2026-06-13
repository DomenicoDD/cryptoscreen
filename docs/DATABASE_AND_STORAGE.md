# Database and Storage Walkthrough

This document explains the cryptoscreen backend in simple terms. It is written for contributors who are technical enough to read code, but who may not already know Postgres, Cloudflare Workers, Neon, or R2.

## Is it safe to publish the database schema?

Yes, for this project the schema is safe to publish.

A database schema is the shape of the database: table names, column names, indexes, constraints, and functions. It is like showing the blueprint of a safe, not the key and not the contents inside it.

The checked-in schema is [database/schema.sql](../database/schema.sql). It does not contain:

- Production database URLs.
- Database passwords.
- Cloudflare credentials.
- R2 access keys.
- Apple keys.
- User plaintext.
- User image plaintext.
- Message link secrets.
- Raw PINs.
- Raw file encryption keys.

Things that must never be committed are already represented as secrets or local-only config:

- `DATABASE_URL`
- `SERVER_PIN_PEPPER`
- Cloudflare API tokens
- App Store Connect keys
- APNs keys
- private `.p8` files
- real `wrangler.jsonc`
- `.env` files

The open-source value is that people can audit how the service stores and deletes data. The security boundary is not "hide the schema." The security boundary is "never store plaintext or decryption keys, and keep production credentials out of Git."

## The main idea

cryptoscreen has three pieces:

- The iOS app encrypts and decrypts on the device.
- The Cloudflare Worker is the public API.
- Neon Postgres and Cloudflare R2 store encrypted data only.

The server stores ciphertext. Ciphertext means encrypted bytes. If someone only has the database row, they should not be able to read the message because the decryption material is derived from the link secret and PIN on the client.

The app must never connect directly to Neon or R2. It talks only to the Worker at `https://cryptoscreen.app/api`.

## What Neon stores

Neon is Postgres. In this project it stores rows such as:

- `sealed_messages`: encrypted text message bytes, cryptographic metadata, PIN attempt metadata, expiry time.
- `message_stats`: one aggregate public counter for shared messages.
- `sealed_message_attachments`: metadata for one encrypted image attachment per message.
- `sealed_message_read_sessions`: short-lived one-time download sessions for encrypted image objects.
- `sealed_message_read_session_events`: best-effort reader events such as screenshot detection.

The important detail is what these tables do not store:

- No message plaintext.
- No image plaintext.
- No link secret.
- No raw PIN.
- No raw image file key.

`pin_verifier` is a server-peppered verifier. The Worker receives a client proof and stores/checks an HMAC using `SERVER_PIN_PEPPER`. This means a database-only leak is not enough to test PIN guesses offline without also having the server secret.

## Why the consume function is in Postgres

Opening a message is a race-sensitive operation. Two recipients, retries, or repeated requests should not be able to open the same normal message twice.

The schema defines `cryptoscreen.consume_sealed_message(...)` as a Postgres function. It does the critical work in one locked database operation:

1. Lock the message row with `for update`.
2. If the row is missing, return `unavailable`.
3. If the row expired, delete it and return `expired`.
4. If the PIN verifier matches, return ciphertext and delete the normal row.
5. If this is the third wrong PIN, delete the normal row and return `destroyed`.
6. Otherwise, increment the failed-attempt counter and return `wrong_pin`.

This is better than doing several separate API queries because it reduces race conditions. The Worker calls one database function and gets one authoritative result.

## What happens to image attachments

Image attachments are designed as a paid/server-backed feature because they create storage and bandwidth costs. They are still compatible with open source because the official hosted service can enforce its own limits server-side.

The app encrypts an image before upload. The Worker receives encrypted bytes only.

The Worker stores:

- encrypted image bytes in a private R2 bucket,
- an R2 object key in Neon,
- encrypted image-key bytes in Neon,
- declared image content type,
- ciphertext size,
- expiry time.

The R2 bucket must not be public. The Worker is the only intended access path.

## How R2 deletion works

There are three deletion paths in the Worker.

First, upload rollback:

1. The Worker writes encrypted bytes to R2.
2. The Worker inserts metadata into Neon.
3. If the Neon insert fails, the Worker deletes the R2 object immediately.

This prevents orphaned objects when upload partially succeeds.

Second, one-time attachment download:

1. After a correct PIN, the message row is consumed.
2. If the message had an attachment, the Worker creates a short-lived read session.
3. The app calls `GET /api/read-sessions/<id>/attachment`.
4. The Worker marks that read session consumed.
5. The Worker reads the encrypted object from R2.
6. The Worker deletes the R2 object.
7. The Worker returns the encrypted bytes in a `no-store` response.

The deletion happens before the response object is returned from the Worker function. If the network drops at the wrong time, the design prefers one-time semantics over retryability: the read session is already consumed.

Third, scheduled cleanup:

1. Cloudflare Cron invokes the Worker's `scheduled()` handler.
2. The Worker finds expired attachment object keys in Neon.
3. It deletes those keys from R2.
4. It calls `cryptoscreen.delete_expired_sealed_messages()` to delete expired database rows and read sessions.

The cleanup path is a backstop for unopened messages, expired read sessions, and any object that did not get deleted during the immediate download path.

## What screenshot events do and do not prove

iOS can tell the app that a screenshot happened, but normal screenshot notification is reactive. The app learns after the screenshot. Screen recording and mirroring can be detected while capture is active.

For attachments, the app can send a generic event to:

```text
POST /api/read-sessions/<read-session-id>/events
```

The event contains only a type such as `screenshot` and a timestamp. It must not contain plaintext, image bytes, PINs, proofs, or full links.

Because the project is open source, a modified client could skip event reporting. An external camera cannot be detected. The feature is useful as an honest best-effort signal, not as a cryptographic guarantee.

## How this fits open source

The public repo can include:

- iOS app source.
- Worker source.
- Database schema.
- Documentation.
- Example Wrangler config.
- Feature gates and entitlement checks.

The public repo must not include:

- production secrets,
- private keys,
- real deployment credentials,
- personal App Store review contact details,
- user data.

Self-hosters can deploy their own Worker, Neon database, and R2 bucket. The official `cryptoscreen.app` service can still charge for features that cost money to run, because the official Worker enforces official-service limits.

## Further reading

- [Cloudflare Workers](https://developers.cloudflare.com/workers/)
- [Cloudflare R2 from Workers](https://developers.cloudflare.com/r2/api/workers/workers-api-usage/)
- [Cloudflare R2 Workers API reference](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)
- [Cloudflare R2 object deletion](https://developers.cloudflare.com/r2/objects/delete-objects/)
- [Cloudflare Cron Triggers](https://developers.cloudflare.com/workers/configuration/cron-triggers/)
- [Neon connection strings](https://neon.com/docs/connect/connect-from-any-app)
- [Neon instant restore / point-in-time restore](https://neon.com/docs/introduction/branch-restore)
- [PostgreSQL `CREATE FUNCTION`](https://www.postgresql.org/docs/current/sql-createfunction.html)
- [PostgreSQL PL/pgSQL structure](https://www.postgresql.org/docs/current/plpgsql-structure.html)
- [PostgreSQL trigger functions](https://www.postgresql.org/docs/current/plpgsql-trigger.html)
- [Apple CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)
- [Apple screenshot notification](https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification)
- [Apple screen capture notification](https://developer.apple.com/documentation/uikit/uiscreen/captureddidchangenotification)
- [Associating an App Clip with a website](https://developer.apple.com/documentation/appclip/associating-your-app-clip-with-your-website)
- [Apple StoreKit](https://developer.apple.com/documentation/storekit)
