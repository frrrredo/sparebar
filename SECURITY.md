# Security

Report vulnerabilities privately through [GitHub Security Advisories](https://github.com/frrrredo/sparebar/security/advisories/new). Include reproduction steps and affected versions. Do not post credentials or account data in issues.

Security fixes target the latest version. This is a personal project; response times are not guaranteed.

Sparebar runs installed official CLIs with your user permissions. It sends only account/usage control requests, caps helper time and output, and stops owned helpers on cancellation. It is not a sandbox for untrusted CLI executables.

The CLIs retain their own authentication, configuration, and network behavior. Sparebar does not persist provider credentials, raw responses, or usage history. See [provider notes](docs/providers.md).

Public CI uses synthetic tests and no provider or signing credentials. Signed distribution will use a separate release setup.
