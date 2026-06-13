# cryptoscreen

cryptoscreen is a native SwiftUI prototype for one-time, privacy-preserving messages. It combines a sealed-message flow with a proximity-style reader: text stays scrambled until the reader covers the top of the screen or uses the manual reveal control.

The current app is intentionally small and native. It encrypts messages on device, stores ciphertext through a Cloudflare Worker API backed by Neon Postgres, and renders plaintext only after the server consumes a one-time read attempt.

## What Works Now

- Create a sealed one-time message.
- Protect the message with a six-digit PIN.
- Generate a shareable deep link with a high-entropy fragment secret.
- Open the message with up to three PIN attempts.
- Delete the encrypted payload after a correct PIN.
- Delete the encrypted payload after the third wrong PIN.
- Delete unopened links after 30 days.
- Render the plaintext through the privacy reader without selectable text.
- Redact the app while screen recording, mirroring, app switching, or shortly after screenshot detection.
- Destroy the visible reader session after iOS reports a screenshot.
- Avoid putting plaintext into logs, clipboard actions, share sheets, or accessibility labels.
- Serve `cryptoscreen.app`, support/privacy pages, and Apple association metadata from Cloudflare Workers.
- V2 design work for Pro encrypted image attachments is tracked in [docs/V2_PRO_IMAGES.md](docs/V2_PRO_IMAGES.md).

The app talks only to `https://cryptoscreen.app/api`. It must never connect directly to Neon.

If you want the backend explained as a lesson, start with [docs/DATABASE_AND_STORAGE.md](docs/DATABASE_AND_STORAGE.md). It explains what is safe to expose in an open-source repo, what the database stores, and how encrypted image objects are deleted from R2.

## Security Model

The production model is:

- The sender encrypts plaintext locally.
- The server stores only ciphertext and metadata.
- The decryption key is not sent to the server.
- The recipient must have both the link secret and PIN.
- The server allows three online PIN attempts.
- A correct PIN atomically returns ciphertext and deletes the row.
- The third wrong PIN atomically deletes the row.
- Unopened links expire and are deleted after 30 days.
- Service-owned retained demo/review rows can be reused for App Review and TestFlight invocation testing.

Read the detailed design in [docs/SECURITY.md](docs/SECURITY.md).

The checked-in database schema is intentionally public in [database/schema.sql](database/schema.sql). It contains structure and deletion logic, not production credentials or user data.

## App Clip Direction

The product target is App Clip first:

1. Sender creates a sealed message.
2. Sender shares a cryptoscreen link.
3. Recipient opens the link.
4. iOS launches the App Clip if the full app is not installed.
5. The App Clip asks for the PIN and consumes the message.

The repo includes an App Clip target that reuses the same reader and sealed-message code in an App Clip-specific open flow. Production App Clip release still requires Apple Developer/App Store Connect configuration, Associated Domains, and on-device invocation testing.

## Build

Requirements:

- Xcode 26.5 or newer
- iOS 17.0 deployment target or newer
- Node.js 22 and pnpm 10 for the Cloudflare Worker

Build from the command line:

```sh
xcodebuild \
  -project PrivacyScreen.xcodeproj \
  -scheme PrivacyScreen \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

Build the App Clip target from the command line:

```sh
xcodebuild \
  -project PrivacyScreen.xcodeproj \
  -scheme PrivacyScreenClip \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

Run with Xcode or the simulator tooling of your choice.

## Cloudflare Worker

Install dependencies:

```sh
pnpm install
```

Create a local Wrangler config:

```sh
cp wrangler.example.jsonc wrangler.jsonc
```

Replace the placeholders in `wrangler.jsonc` with your Cloudflare account, domain, and Apple app values. The real `wrangler.jsonc` is intentionally ignored by Git because it contains deployment-specific identifiers.

Generate Worker types and validate the bundle:

```sh
pnpm run types
pnpm run check
```

Required production secrets:

```text
DATABASE_URL
SERVER_PIN_PEPPER
```

Deploy after Cloudflare CLI auth is available:

```sh
pnpm exec wrangler secret put DATABASE_URL
pnpm exec wrangler secret put SERVER_PIN_PEPPER
pnpm run deploy
```

For the first deployment of a new Worker, Wrangler may require the secrets before `wrangler secret put` can target an existing script. In that case, deploy once with `wrangler deploy --secrets-file <temporary-json-file>`, then delete the temporary file immediately.

The Worker serves:

- `/` web landing page
- `/privacy` App Store privacy URL
- `/support` App Store support URL
- `/m/<message-id>` universal link and App Clip invocation page
- `/.well-known/apple-app-site-association`
- `/api/stats`
- `/api/feedback`
- `/api/messages`
- `/api/messages/<message-id>/attachment`
- `/api/messages/<message-id>/consume`
- `/api/read-sessions/<read-session-id>/attachment`
- `/api/read-sessions/<read-session-id>/events`

V2 encrypted image attachments use a private Cloudflare R2 bucket bound to the Worker as `ATTACHMENTS`. The bucket must not be public; all upload and download access goes through the Worker. The checked-in `wrangler.example.jsonc` includes the required binding shape.

Optional public-site variables:

```text
GITHUB_REPOSITORY_URL
X_PROFILE_URL
SUPPORT_EMAIL
FEEDBACK_EMAIL
FEEDBACK_FROM_EMAIL
```

`/api/feedback` sends onboarding feedback through a server-side Cloudflare `send_email` binding named `FEEDBACK_EMAIL_SENDER`. The iOS app never receives SMTP or email-provider credentials.

## Project Structure

```text
PrivacyScreen/
  CaptureShield.swift          Screen recording, screenshot, and app-switcher redaction
  PrivacyReaderView.swift      Scrambled/revealed reader UI
  ProximitySensor.swift        Proximity/manual reveal state
  SealedMessageAPI.swift       Cloudflare Worker API client
  SealedMessageCrypto.swift    Client-side sealing, PIN proof, link parsing
  SealedMessageRootView.swift  Compose/open/read flow
  TextLineWrapper.swift        Monospaced line wrapping and scramble helpers
PrivacyScreenClip/
  Info.plist                   App Clip metadata
  PrivacyScreenClip.entitlements
database/
  schema.sql                   Neon/Postgres schema and atomic consume function
docs/
  DATABASE_AND_STORAGE.md      Beginner-friendly backend and storage walkthrough
  SECURITY.md                  Threat model and production API/database design
  V2_PRO_IMAGES.md             Pro encrypted image attachment architecture
.github/
  ISSUE_TEMPLATE/              Public issue templates
  PULL_REQUEST_TEMPLATE.md     Contributor pull request checklist
src/
  worker.ts                    Cloudflare Worker website and API
wrangler.example.jsonc         Copyable Worker config template
```

## Important Limitations

- Normal screenshots cannot be prevented reliably with public iOS APIs. The app can redact and destroy the visible reader session after screenshot notification, and it can redact during screen recording/mirroring.
- The App Clip target is present and builds locally, but still needs production invocation testing from a real App Clip URL.
- Associated Domains and App Clip capabilities must be enabled for the Apple App IDs before TestFlight/App Store signing with entitlements.
- A six-digit PIN is not enough by itself. The design requires the high-entropy link secret plus the PIN.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and open pull requests using the template in `.github/`.

For vulnerabilities, do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
