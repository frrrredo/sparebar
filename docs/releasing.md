# Releases

CI tests and archives each `main` build. Release that exact archive; do not rebuild it locally. Signing and Apple credentials stay in your Mac's Keychain, outside public Actions jobs.

You need Xcode command-line tools, Python 3, `gh`, and a personal Developer ID Application certificate. Reuse a valid notarization Keychain profile if you have one. Otherwise, save an App Store Connect API key for the same developer team:

```sh
xcrun notarytool store-credentials sparebar \
  --key PRIVATE_KEY_PATH --key-id KEY_ID --issuer ISSUER_ID
security find-identity -v -p codesigning
```

Apple ID authentication also works: use `--apple-id EMAIL --team-id TEAM_ID` instead of the key options. The secure prompt takes an app-specific password, and that Apple ID must belong to the signing team.

1. Bump both versions in `Resources/Info.plist`, update the changelog and `Resources/ReleaseNotes.txt`, and merge through a PR. The first notes line is one user-focused sentence, at most 180 characters. The remaining text is the full plain-text notes shown inside Sparebar; keep all notes under 12000 characters.
2. Choose the successful **push to main** CI run in Actions. Archives expire after 30 days.
3. Use the certificate's SHA-1 and developer team ID:

```sh
python3 scripts/release.py prepare CI_RUN_ID \
  --identity CERTIFICATE_SHA1 --team-id TEAM_ID --notary-profile sparebar
```

The script validates the source and checksum, signs Sparkle's nested helpers and then the app with Hardened Runtime, notarizes and staples both app and DMG, and checks the app copied from the mounted image. It signs the final DMG for Sparkle using the local `sparebar` Keychain account and writes `appcast.xml`. The archived app's public key must match that signing key. No private key is sent to GitHub.

For a new signing Mac, use Sparkle's `bin/generate_keys --account sparebar` only when intentionally creating a new key. Preserve or securely transfer the existing key when changing Macs; do not replace the public key casually. The pinned Sparkle tools are in `.build/artifacts/sparkle/Sparkle/bin/` after `swift package resolve`. A changed Sparkle version also requires refreshing `Resources/Sparkle-files.json` after inspecting the framework's file/link inventory.

Local Apple diagnostics go to ignored `dist/notary-logs/`. Upload the DMG, `SHA256SUMS`, `release.json`, and `appcast.xml` together to a **draft** GitHub release. Verify the assets, then publish the draft. The published event runs **Publish update feed**, including for prereleases. That workflow validates the appcast against the published DMG and commits `appcast.xml` to the dedicated `updates` branch. The app reads the public raw file there; no additional hosting or signing credentials are needed in Actions. Do not publish first and upload the appcast afterward.

Check that **Publish update feed** succeeds before calling the rollout complete. If publication needs retrying, run that workflow manually with the numeric release ID. It is idempotent, preserves earlier entries, orders by build number, and refuses to replace an existing build. Never trigger it for old releases that lack updater metadata. GitHub repository Actions must have permission to write the `updates` branch.

Open the DMG and test a drag-to-Applications install, launch, and both connections. Publish a GitHub prerelease targeting the exact `commit` in `release.json`. Never replace an existing tag or release asset; use a new version for a changed build.

The first updater-enabled release must be installed manually by users of 0.1.2 and earlier. To verify the updater itself, test an older and a newer signed, notarized build with the same bundle ID and Sparkle key in an isolated installation. Exercise background installation on quit, explicit update/restart, cancellation, unavailable network, and signature rejection. Unit tests and a demo do not prove a completed real installation.

Launch-at-login after a real login, sleep/wake, VoiceOver, and sustained battery use still need manual verification. Keep those limits in release notes until checked.

[Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
