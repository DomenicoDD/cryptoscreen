# Links and browser reading

## Website-to-app flow

The app continues sharing `https://cryptoscreen.app/m/<uuid>#s=<secret>`.

- Tapping that link in Messages or Notes lets iOS open the installed app through its existing `applinks:cryptoscreen.app` association.
- Entering the URL in a browser address bar opens the website. On iPhone/iPad, the page moves to `https://www.cryptoscreen.app/m/<uuid>#s=<secret>` using `location.replace`.
- The **Open in app** button is a genuine user tap from `www` to the associated apex domain, carrying the complete fragment. This supports the currently released full app without adding a new associated domain.
- **Open App Clip** targets `https://cryptoscreen.app/m/<uuid>?clip=1#s=<secret>`. That page stays on the App Clip's associated domain and declares `app-clip-display=card`. The person taps Apple's native Open control. Its Back to message link keeps the fragment.
- The full app's Smart App Banner receives `app-argument` with the complete URL, updated client-side. The App Clip uses the actual page's invocation URL; Apple does not pass `app-argument` to App Clips.
- App-opening actions appear only on iOS. Android also hides App Store download buttons, including on the homepage. Sender-approved browser reading remains available on Android and desktop.

`APP_BASE_URL` and `WEB_BASE_URL` are explicit Wrangler variables. Both custom domains must route to this Worker. Do not add `www` to the app's `applinks` entitlement: the fallback host is deliberately a website.

No decryption secret is put in a query, server-generated HTML, redirect header, or browser session storage. Client-side navigation and anchors preserve it only after `#`. Message pages have `Cache-Control: no-store` and request no indexing. The CSP allows only the exact inline script hashes; `pnpm test` catches stale hashes.

There is no supported way to force iOS to launch an installed app simply by typing into the address bar. A tap on the app link/banner/card is still required. In-app browsers and user preferences can affect handoff; Safari is the fallback.

## App Clip release requirements

The shared root view handles both SwiftUI `.onOpenURL` and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`, forwarding `activity.webpageURL` to the message reader. A new incoming link clears the prior PIN and dismisses onboarding.

The website cannot add this handler to an already-installed/released binary. Release an app version containing the updated Clip.

In App Store Connect, verify that:

1. The app version includes `com.domenico.privacyscreen.Clip` and is released with a configured default App Clip experience.
2. If an advanced experience is configured, its URL prefix covers `https://cryptoscreen.app/m/`, including the dedicated `?clip=1` page. Use a generic prefix, not a specific private message.
3. The Clip and parent app remain associated with `cryptoscreen.app`, matching the Worker AASA app identifiers.

On a physical iPhone, verify installed-app opening from Messages, an address-bar visit followed by Open in app, and the Clip flow after removing the full app from the test device. Use a newly created disposable message for each consumed read. Safari's native App Clip card requires a published Clip, a configured experience, supported device settings, and Safari/SFSafariViewController outside Private Browsing. Native cards do not appear in the iOS simulator.

## Browser-reading readiness

The existing sender UI already exposes **App only** and **App or web**, in both the full app and the Messages extension. Both send the selected `readPolicy` to the API. The default remains `app_only`.

The production API and database already support `web_allowed`. The Worker applies the idempotent read-policy schema setup on relevant requests. No new database migration or package dependency is required for this change. Older messages stay app-only; the recipient cannot enable browser reading. The sender must create a new message with **App or web** selected in the updated app.

For browser-enabled messages, the website:

- Checks status and read policy, validates the fragment, and requires Web Crypto before offering the PIN form.
- Derives the same HKDF-SHA256/HMAC PIN proof as Swift CryptoKit and submits `readerClient: "web"` with telemetry opt-out.
- Decrypts AES-GCM text and optional encrypted image/file-key payloads locally. It sends no plaintext, raw PIN, or link secret to the server.
- Prevents duplicate submissions and further attempts after consumption or destruction.
- Preserves opened text if the attachment fails, reports unsupported image formats, and clears rendered content/object URLs on Close or page exit (including browser history restoration).

Browsers do not have the native capture shielding or screenshot-destruction behavior. The warning on the PIN form makes that distinction, and the app's share text no longer promises screenshot destruction to web recipients. Some browsers cannot display HEIC/HEIF; JPEG and PNG are the portable formats. The current API's `readerClient`/`readPolicy` is a product-level gate for supported clients, not native app attestation.

The status query now excludes expired messages from its active-message CTE. PostgreSQL data-modifying CTEs share a snapshot, so merely deleting expired rows in a sibling CTE did not prevent the same response from reporting one as active.

## Verification

```sh
pnpm test
pnpm run check
```

`pnpm test` compiles a synthetic fixture using the actual Swift crypto source, then executes the emitted website scripts with real Web Crypto. It covers device routing, fragment preservation, CSP, App Clip metadata, policy gating, text/image decryption, duplicate submissions, wrong PINs, consumed errors, and clearing.

The explicit live smoke test creates three synthetic messages with a five-minute TTL, consumes them, and expires any remaining test rows. It affects the aggregate message counter. It never reads or consumes an existing user's message:

```sh
node scripts/smoke-browser-reading.mjs https://cryptoscreen.app https://www.cryptoscreen.app
```

Also build the full app scheme, which embeds the App Clip and Messages extension. Physical-device handoff and App Store Connect experience checks remain separate from a successful build or browser test.

References: [Apple universal-link debugging](https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links), [App Clip website and Messages invocations](https://developer.apple.com/documentation/appclip/supporting-invocations-from-your-website-and-the-messages-app), [Responding to App Clip invocations](https://developer.apple.com/documentation/appclip/responding-to-invocations).
