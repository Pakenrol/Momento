Security Policy
===============

Reporting a Vulnerability
- Please email security reports to: security@pakenrol.dev (or open a private GitHub advisory)
- Provide a clear description, reproduction steps, and impact assessment.
- We will acknowledge within 5 business days.

Best Practices We Follow
- No bundled secrets in repo; release signing done via CI secrets.
- Sparkle updates over HTTPS; EdDSA signatures recommended.
- Hardened Runtime and Developer ID signing for distributed builds.

