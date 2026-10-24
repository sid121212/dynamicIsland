# Local validation — 0.5.1 (11)

Final packaging status: completed after the owner approved Keychain access. The final candidate includes Sparkle licence notices and passed independent EdDSA verification inside the packaging script.

- Full arm64 release app built and signed with NotchDev. Nested Sparkle helpers and enclosing app passed deep strict code signature verification. Runtime flag enabled; TeamIdentifier absent as expected for this self-signed identity.
- Sparkle Keychain public key matches the user-supplied/embedded key. No private keys exported or committed.
- Native regression suite passed, including launch-location path rules. Both NOTARIZED flag variants type-check.
- Six release validation tests passed, including mocked draft-first stable/beta publication. Healthcheck mocks cover good URLs, creating an issue, and commenting on an existing issue; no real issue was opened. Workflow YAML and shell syntax parse.
- DMG created by pinned create-dmg, Applications link and Finder layout generated; hdiutil verify passed.
- ZIP EdDSA verified with independent CryptoKit code against the public key embedded in the built app. A tampered archive was rejected. Appcast records build 11, version 0.5.1, macOS 15+, arm64, signed ZIP and embedded release notes.
- DMG size: 1425690 bytes. SHA-256: `cc3429158249b04a1d01fc28903915f246dce0231665e915c207c3cad86ee0c5`. Sidecar matches.
- Website build, TypeScript, ESLint, release/support checks pass. Download area shows Open Anyway help and source/release links; versioned DMG asset/checksum selection is covered by fixtures. Notch remains in testing until public-release acceptance.

Not run: clean-Mac Gatekeeper installation, user approval behavior, actual two-version Sparkle replacement/relaunch, TCC continuity, live GitHub Actions/secrets or public publication. No tag/release pushed and no deploy hook called. Follow TESTING.md before publishing.

## Self-hosted changes validated 2026-10-24

Built a separate QA app using SITE_URL=https://release-test.invalid and CONTACT_EMAIL=qa@release-test.invalid. NotchDev signing and deep strict verification pass; Info.plist, Resources and executable pass the forbidden-host guard. Typechecking passes with both notarization flags. Existing native regression checks pass; nine release-validation tests and healthcheck mocks pass, including rejection at exactly 25 MiB and rejection of a forbidden Resource fixture.

QA package is isolated under build/qa-selfhost-dist/0.5.1 (not dist/0.5.1): DMG 1,424,110 bytes, ZIP 1,605,327 bytes. DMG SHA-256 e774ffc3180dd1c24bcfafca6fa4705bde681bc54c15146db1af0b2ef72fe4da. Appcast has a single same-origin ZIP enclosure and embedded notes; independent CryptoKit verifies the ZIP's EdDSA signature. Sidecars exist for every non-sidecar asset, and the actual signed artifacts passed the site's mirror validator using a local API fixture (no remote publication).

These are test-origin artifacts and must not be distributed. No production origin, CI secrets, hosting deployment, clean-Mac installation or two-version installed update has been validated. The older dist/0.5.1 package remains unchanged with its earlier feed. A new version/build with the real origin is required for distribution; an already-installed app with the private feed needs a manual installation of that new version.
