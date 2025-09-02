Contributing to Momento
=======================

Thanks for your interest in contributing! This project aims to provide a simple, fast AI upscaler for macOS.

How to contribute
- Issues: open clear, reproducible issues with logs and environment details.
- Features: discuss in an issue before large changes.
- PRs: keep focused and small. Follow existing style and avoid unrelated refactors.

Development setup
- Requirements: Xcode 15+, macOS 13+.
- Build: `swift build -c release`
- Package app: `PACKAGE_ONLY=1 ./scripts/package_app.sh`
- Create DMG: `MAKE_DMG=1 PACKAGE_ONLY=1 ./scripts/package_app.sh`

Models
- We do not commit large models. Use the in‑app “Download AI Models” button or fetch from Release assets.
- Models are stored in `~/Library/Application Support/Momento/Models`.

Code style
- Swift 5.9+, prefer clarity over cleverness.
- Keep UI minimal and responsive. Avoid blocking the main thread.

Security
- Never commit secrets, certificates, or private keys.
- See SECURITY.md for vulnerability reporting.

License
- By contributing, you agree your contributions are licensed under the MIT License.

