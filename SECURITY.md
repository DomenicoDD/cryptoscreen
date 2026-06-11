# Security Policy

cryptoscreen handles sensitive message workflows. Please report vulnerabilities privately instead of opening public issues.

## Supported Versions

The project is pre-1.0. Security fixes target the current `main` branch unless a released version is explicitly listed later.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting for the published repository. If private vulnerability reporting is not enabled yet, contact the maintainer privately through the repository owner profile before sharing details publicly.

Include:

- A clear description of the issue.
- Steps to reproduce or a proof of concept.
- The affected component: iOS app, App Clip direction, Worker API, database schema, deployment config, or documentation.
- Any known impact or mitigation.

Do not include real user messages, production credentials, database dumps, or secrets in the report.

## Scope

In scope:

- Plaintext, PIN, link-fragment, or proof leakage.
- Weaknesses in the one-time consume flow.
- Database race conditions around attempts and deletion.
- Worker API validation or authorization flaws.
- Deployment mistakes that could expose secrets or private data.

Out of scope:

- Physical-device photography of the screen.
- Claims that normal iOS screenshots can always be blocked before capture.
- Issues requiring compromised Apple, Cloudflare, Neon, or maintainer accounts.

## Disclosure

Please give the maintainer reasonable time to investigate and patch before public disclosure. The security architecture is documented in `docs/SECURITY.md`.
