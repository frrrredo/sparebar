# Releases

CI tests and archives each `main` build. Release that exact archive; do not rebuild it locally. Signing and Apple credentials stay in your Mac's Keychain, outside public Actions jobs.

You need Xcode command-line tools, Python 3, `gh`, and a personal Developer ID Application certificate. Reuse a valid notarization Keychain profile if you have one. Otherwise, save an App Store Connect API key for the same developer team:

```sh
xcrun notarytool store-credentials sparebar \
  --key PRIVATE_KEY_PATH --key-id KEY_ID --issuer ISSUER_ID
security find-identity -v -p codesigning
```

Apple ID authentication also works: use `--apple-id EMAIL --team-id TEAM_ID` instead of the key options. The secure prompt takes an app-specific password, and that Apple ID must belong to the signing team.

1. Bump both versions in `Resources/Info.plist`, update the changelog, and merge through a PR.
2. Choose the successful **push to main** CI run in Actions. Archives expire after 30 days.
3. Use the certificate's SHA-1 and developer team ID:

```sh
python3 scripts/release.py prepare CI_RUN_ID \
  --identity CERTIFICATE_SHA1 --team-id TEAM_ID --notary-profile sparebar
```

The script validates the source and checksum, signs with Hardened Runtime, notarizes and staples both app and DMG, and checks the app copied from the mounted image. Local Apple diagnostics go to ignored `dist/notary-logs/`; publish only the DMG, `SHA256SUMS`, and `release.json` from `dist/releases/VERSION/`.

Open the DMG and test a drag-to-Applications install, launch, and both connections. Publish a GitHub prerelease targeting the exact `commit` in `release.json`. Never replace an existing tag or release asset; use a new version for a changed build.

Launch-at-login after a real login, sleep/wake, VoiceOver, and sustained battery use still need manual verification. Keep those limits in release notes until checked.

[Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
