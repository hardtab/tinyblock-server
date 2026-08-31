# Security policy

## Reporting a vulnerability

Please report security vulnerabilities to **security@nosuchgames.com**.

Do not open a public GitHub issue for security-sensitive bugs.

## Scope

- The dedicated server binary built from this repository.
- The world persistence implementation (save/load paths).
- The multiplayer protocol implementation.
- Authentication and session handling for the backend API.

## Out of scope

- General Tiny Block client vulnerabilities (report through the same email).
- Vulnerabilities in third-party dependencies (report according to their policies).
- Backend API infrastructure operated by No Such Games.

## Response timeline

We aim to:

1. Acknowledge receipt within 48 hours.
2. Provide an initial assessment within 5 business days.
3. Release a fix or mitigation within 30 days for critical issues.

## Safe harbor

We support coordinated disclosure. Researchers who report vulnerabilities in good faith will not face legal action from No Such Games.

## Ban mechanism

Tiny Block operators maintain a manual host ban list. A banned host cannot create publicly listed sessions. To report a malicious server: email security@nosuchgames.com with the server's world name, observed behavior, and approximate time.
