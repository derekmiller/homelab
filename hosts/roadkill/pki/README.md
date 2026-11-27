# Caddy internal root CA

`caddy-root.crt` is the **public** root certificate of the Caddy that serves the
`edge` stack. It is installed in the trust stores of the phone and the Mac so
that `*.roadkill.lan` serves valid HTTPS.

- Subject / issuer: `CN=Caddy Local Authority - 2026 ECC Root` (self-signed)
- Valid: 2026-11-23 → **2036-10-01**
- SHA-256: `<paste the fingerprint openssl printed>`

Public material — safe to commit. The matching private key
(`…/pki/authorities/local/root.key` inside Caddy's data directory) must never be
committed; `.gitignore` covers `*.key`.

If Caddy's data volume is recreated the CA is regenerated, every leaf cert
becomes untrusted, and this file must be replaced and re-installed on each
device. Verify a device has the same root by comparing the SHA-256 above.
