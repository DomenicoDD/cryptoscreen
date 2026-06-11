# Contributing to cryptoscreen

Thanks for considering a contribution. cryptoscreen is privacy-sensitive software, so the main rule is simple: changes should make the product easier to trust, inspect, and operate.

## Good First Areas

- SwiftUI reader polish and accessibility checks that do not expose plaintext.
- App Clip setup and universal-link handling.
- Worker validation, rate limiting, and operational hardening.
- Tests for cryptographic encoding, link parsing, API status handling, and database consume behavior.
- Documentation, diagrams, screenshots, and threat-model clarifications.

## Local Setup

Requirements:

- Xcode 26.5 or newer
- iOS 17.0 deployment target or newer
- Node.js 22
- pnpm 10

Install Worker dependencies:

```sh
pnpm install
```

Create a local Wrangler config:

```sh
cp wrangler.example.jsonc wrangler.jsonc
```

Then replace the placeholders in `wrangler.jsonc` with your Cloudflare, Apple, and domain values. Keep production secrets out of Git.

Validate the Worker:

```sh
pnpm run types
pnpm run check
```

Build the iOS app:

```sh
xcodebuild \
  -project PrivacyScreen.xcodeproj \
  -scheme PrivacyScreen \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

## Security Rules

- Do not log plaintext, PINs, link fragments, PIN proofs, database URLs, or secret values.
- Do not send the link fragment secret to the server.
- Do not add direct Neon/Postgres access to the iOS app or App Clip.
- Do not make plaintext selectable, copyable, shareable, or available through accessibility labels.
- Treat screenshots and screen recording as best-effort redaction only; do not claim perfect prevention.
- If a change affects the security model, update `docs/SECURITY.md` in the same pull request.

## Pull Requests

Before opening a pull request:

- Keep the change focused.
- Run the relevant checks.
- Include screenshots or screen recordings for visible UI changes.
- Call out any security, privacy, or migration impact.
- Add or update tests when behavior changes.

For security vulnerabilities, do not open a public issue. Follow the reporting process in `SECURITY.md`.
