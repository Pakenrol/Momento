Momento — AI Video Upscaler for macOS
=====================================

Momento is a native macOS app focused on restoring old 360p era videos into clean HD/4K using modern AI techniques. It prioritizes a simple workflow (file → process) while selecting the best available pipeline under the hood.

Status: Core ML pipeline (FastDVDnet + RealBasicVSR x2) is implemented. NCNN fallbacks (RealCUGAN/Waifu2x/Real-ESRGAN) are planned for future integration in this repo; the current binary release may bundle models separately.

Why Momento
- Simple UI: drag & drop, one “Start” button.
- Smart pipeline: automatic choice of best available method.
- Local and fast: optimized for Apple Silicon, uses Core ML, VideoToolbox.
- Designed for 90s–2000s footage: denoise + VSR tuned for real world material.

System Requirements
- macOS 13.0+
- Apple Silicon (M1/M2/M3) or Intel Mac
- 16 GB RAM recommended

Build From Source (SwiftPM)
1) Xcode 15+ or Xcode command line tools installed.
2) In the project root:
   - Build: `swift build -c release`
   - Package into .app (no install): `PACKAGE_ONLY=1 ./scripts/package_app.sh`
   - Create DMG: `MAKE_DMG=1 PACKAGE_ONLY=1 ./scripts/package_app.sh`
   The app bundle will be produced in `dist/Momento.app` and DMG in `dist/Momento-<version>.dmg`.

Optional: Sparkle Updates
Momento includes a compile‑time optional “Check for Updates…” menu (no-op unless Sparkle is linked). To enable Sparkle 2:
- In Xcode: File → Add Packages… and add `https://github.com/sparkle-project/Sparkle`.
- Programmatic setup is already included (`Updates.swift`). When Sparkle is present, Momento shows a working “Check for Updates…” menu and performs automatic background checks.
- Configure Info.plist keys (our packaging script supports env vars):
  - `SUFeedURL` → your HTTPS appcast URL
  - `SUPublicEDKey` → your EdDSA public key
  - `SUEnableAutomaticChecks` → true
- Generate keys and appcast using Sparkle’s tools (found under Sparkle’s binary artifacts):
  - Generate keys: `./bin/generate_keys` → copy `SUPublicEDKey` into Info.plist
  - After building a signed DMG/ZIP, run: `./bin/generate_appcast path/to/updates/`

Security Notes for Sparkle
- Serve updates over HTTPS.
- Code sign your app with Apple Developer ID for distribution.
- Sign the update archive with Sparkle’s EdDSA signature.
- Keep your private keys safe; do not store them in the repository.

Distributing Releases
Recommended path for GitHub:
- Create a signed & notarized DMG/ZIP and upload it as a GitHub Release asset.
- Host your `appcast.xml` via GitHub Pages (docs/ folder) and set `SUFeedURL` accordingly.
- CI provided in `.github/workflows/release.yml` builds the DMG, generates an appcast (signed if `SPARKLE_PRIVATE_KEY` is set), creates a GitHub Release, and publishes the appcast to Pages.

Repository Hygiene (Open Source)
- Do not commit model weights or huge artifacts. Prefer hosting them as release assets or provide a script to obtain them.
- Use Git LFS if you must version large binaries (note GitHub has LFS bandwidth limits).
- Ensure `.gitignore` excludes `.build/`, `dist/`, `*.app`, `venv*/`, and test outputs.

Roadmap
- Integrate NCNN fallbacks (RealCUGAN / Waifu2x / Real‑ESRGAN) behind an automatic chooser.
- RIFE frame interpolation in “Quality” mode.
- Batch processing, preview, and hardware tuning.

How It Works (Current)
- Extract frames → Core ML denoise (FastDVDnet) → Core ML super‑resolution (RealBasicVSR x2) → reassemble with VideoToolbox HEVC.
- Progress with ETA and cancel support are built in.

Developer Commands
- Package and install locally: `./scripts/package_app.sh` (installs to `/Applications`).
- Package only (CI-friendly): `PACKAGE_ONLY=1 ./scripts/package_app.sh`.
- Create DMG only from existing bundle: `./scripts/make_dmg.sh`.

Adding Sparkle in Detail (Xcode UI)
1) Open the folder in Xcode. File → Add Packages… → `https://github.com/sparkle-project/Sparkle`.
2) Ensure the Sparkle package is added to the Momento target.
3) In target’s Info, add:
   - `SUFeedURL` = `https://your-domain.example.com/appcast.xml`
   - `SUPublicEDKey` = `<your key>`
   - `SUEnableAutomaticChecks` = `YES`
4) Archive (Product → Archive) and distribute with Developer ID. This ensures Sparkle’s helper tools are correctly signed.
5) Generate appcast with Sparkle’s `generate_appcast` and upload the archive + appcast to your hosting. New versions will be picked up automatically.

Licensing & Contributions
- Choose a license (MIT/Apache‑2.0 are good defaults) and add a `LICENSE` file.
- Add `CONTRIBUTING.md`, `SECURITY.md`, and (optionally) a `CODE_OF_CONDUCT.md`.

Privacy
Momento runs fully offline on your Mac. No files or telemetry are uploaded.

Model Management
- In-app: click “Download AI Models” to fetch `FastDVDnet.mlpackage` and `RealBasicVSR_x2.mlpackage` into `~/Library/Application Support/Momento/Models`.
- Configure the download base URL by setting `ModelDownloadBaseURL` in Info.plist (packager env: `MODEL_BASE_URL`). Default points to GitHub Releases latest downloads.
- The app searches for models in Application Support first, then the app bundle (if embedded for internal testing).

CI Secrets (optional, for full automation)
- `CODESIGN_IDENTITY`: e.g. "Developer ID Application: Your Name (TEAMID)" if you import certs in CI.
- `SPARKLE_FEED_URL`: HTTPS URL to your appcast (e.g. https://<user>.github.io/<repo>/appcast.xml).
- `SPARKLE_PUBLIC_ED_KEY`: Your EdDSA public key (base64) for Info.plist.
- `SPARKLE_PRIVATE_KEY`: EdDSA private key contents used by `generate_appcast` to sign archives.
- `APPCAST_DOWNLOAD_BASE`: Base URL used in fallback appcast generation (e.g. https://github.com/<user>/<repo>/releases/download/vX.Y.Z).

Acknowledgements
- FastDVDnet, RealBasicVSR (Core ML conversions)
- Sparkle (updates)
- FFmpeg / VideoToolbox
