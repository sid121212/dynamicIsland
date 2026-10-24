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
