# Releasing the free, self-signed Mac app

This pipeline uses **no Apple Developer Program, notarization, Homebrew, license server or sponsor check**. Every public app remains free. Sparkle verifies update archives using EdDSA; this does not make the first downloaded app trusted by Gatekeeper. Recipients may need Open Anyway. Never ask them to disable Gatekeeper, strip quarantine globally, or trust our certificate as a root.

## Public URLs and private storage

Both repositories remain private. Users download only from `${SITE_URL}/download/notch/`; Sparkle uses `${SITE_URL}/downloads/notch/appcast.xml` and same-origin ZIP enclosures. Set the **final HTTPS origin** in repository variable `SITE_URL` and `CONTACT_EMAIL` for mail drafts. Placeholder or missing origins and missing contact addresses fail builds. Keep the origin stable for already-installed apps. The source Info.plist contains an injection marker; only build.sh's stamped copy is distributable.

`release.config.json` defines slug `notch`, storage repository `sid121212/dynamicIsland`, signing identity `NotchDev`, arm64/macOS 15+, and the public EdDSA key. The committed public EdDSA key is `R5tnNRqzvurYtEoBF+JYYYkGNPW4zPhD8i5c09+rnws=`. No source repository URL is embedded in the app. Sparkle 2.10.0 remains pinned.

The old 0.5.1/build 11 artifacts in `dist/0.5.1` embed the old feed. Do not mirror or republish them as a self-hosted update. Choose a new semver and increasing build, add reviewed release notes, and rebuild with the real site origin. The local QA app may use `release-test.invalid`; it must never be shipped.

## Tools, without Homebrew

Install Xcode or current Command Line Tools, Swift 6.2+ and the official [CMake distribution](https://cmake.org/download/). Put CMake on PATH. Obtain [GitHub CLI from its official release](https://github.com/cli/cli/releases) and authenticate with `gh auth login` when ready to publish. Do not install tools into the app; recipients need none of them.

Run `scripts/bootstrap-release-tools.sh`. It resolves Sparkle through SwiftPM and downloads official create-dmg v1.3.0 source under ignored `build/tools/`, verifying the pinned tag and commit. Sparkle's tools live at `.build/artifacts/sparkle/Sparkle/bin/`. `CREATE_DMG` may point to a separately installed official create-dmg executable.

## Signing identity and backup

Use Keychain Access → Certificate Assistant → Create a Certificate. Name: **NotchDev**. Identity Type: Self Signed Root. Certificate Type: **Code Signing**. Keep its private key. On the signing Mac only, trust that certificate for code signing if necessary so `security find-identity -v -p codesigning` lists it as valid. Do not change TLS or system-wide security settings and do not distribute trust instructions to recipients.

Export the identity **with its private key** as a password-protected `.p12` using a strong, unique password. Back it up offline in two separate, preferably encrypted locations. Keep the password separately. Do not send it through chat or commit it. Export only the intended identity, not every key in the login keychain.

`build.sh` requires a valid configured identity and fails before altering the app if it is absent. Set `SIGNING_IDENTITY=NotchDev` or a SHA-1 fingerprint to select it. There is no ad-hoc fallback. All Sparkle Mach-O helpers, XPC services, Updater.app and the framework are re-signed inside-out with that identity before the enclosing app. Sparkle helper entitlements are preserved. The app gets hardened runtime and `Resources/Entitlements.plist`; no timestamp or notarization is claimed.

**Self-signed framework loading:** the app has `com.apple.security.cs.disable-library-validation=true` because a self-signed identity has no Apple Team ID. Hardened runtime otherwise rejects embedded third-party code in this setup. This is an app-scoped entitlement, not disabling Gatekeeper or system protections. Signed update archives still have to pass Sparkle's EdDSA verification. Test framework loading, helper launch and replacement on a clean Mac; same-certificate signing alone is not proof that a full update works.

## Sparkle keys and backup

For an existing key, do **not** generate a replacement casually. On the owner’s Mac:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /path/outside/repository/sparkle-private-key
```

The default command creates the pair only when none exists, stores the private key in login Keychain and prints the public key. `-p` only looks up the existing public key. Confirm that it matches the public key above. `-x` exports the private material, which must be backed up offline in two places, preferably encrypted. Use restrictive file permissions. Never print it, put it in a command argument, or commit it. Ignore rules cover `.p12`, `.key`, keychain files, `*private-key*`, `.env*` and `secrets/`; backups belong outside the repository regardless.

The provided public key alone cannot sign an update. A lost EdDSA key without a Developer ID recovery path can require a manual reinstall; preserve the private key and certificate across machines and releases. Do not rotate the signing certificate or public key without testing a migration.


## Private release and public mirror pipeline

App repository Actions secrets: `SIGNING_P12_BASE64`, `SIGNING_P12_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`, and `SITE_DISPATCH_TOKEN` (fine-grained contents-write access to the private site repo). Variables: `SITE_URL`, `CONTACT_EMAIL`, optional `SITE_REPOSITORY` (defaults to `sid121212/zero-dollar-labs`), optional `SPARKLE_PUBLIC_ED_KEY`. The certificate is imported in a temporary keychain, trusted only for code signing on that runner, and removed on exit. No Homebrew or Apple Developer Program is used.

Site repo and hosting build secret: `RELEASES_READ_TOKEN`, read-only contents/releases access to all private app repos. Site repo secret: `SITE_DEPLOY_HOOK_URL`, the Cloudflare Pages build hook. The site repository and hosting build read the origin only from `NEXT_PUBLIC_SITE_URL`; app repositories read it only from `SITE_URL`. The website contact address is stored once as `CONTACT_EMAIL` in site.config.ts; app repositories store the matching address in the `CONTACT_EMAIL` variable. Never expose release tokens using a public environment-variable prefix.

1. Set a new `CFBundleShortVersionString` and strictly increasing integer `CFBundleVersion` in Resources/Info.plist, write `docs/release-notes/<version>.html`, commit, and tag that exact clean commit `v<version>`.
2. Push the tag to run release.yml, or check out the clean tagged commit and run `SITE_URL=https://your-real-host CONTACT_EMAIL=your-address scripts/release.sh <version> <build>`. Release.sh publishes; use package-artifacts.sh only for packaging an already-built app.
3. The release creates the DMG with a drag-to-Applications layout and a ZIP using ditto. Both must be **strictly smaller than 25 MiB**. Sizes print before appcast generation; oversized files stop publication.
4. Sparkle generates the appcast from an isolated folder containing one ZIP plus its HTML notes. Enclosures must match the site prefix and expected version/build/length. An independent CryptoKit verification checks the ZIP's EdDSA signature against the app's public key.
5. Assets include DMG, ZIP, appcast.xml, release-notes.md, HTML notes and a `.sha256` sidecar for every non-sidecar file. Extra sidecars let the site verify the ZIP, appcast and notes as well as the DMG. A draft release is published only after uploads succeed. Beta tags are pre-releases and never become latest stable.
6. The final release.yml step dispatches `app-released` with slug/version to the site repo. Dispatch failure fails the job; the release remains published. Retry only the failed dispatch step, not immutable artifact publication.
7. Site CI/hosting runs fetch-releases.ts, verifies all required assets, retains three non-draft releases, mirrors only the stable feed, prunes other files, generates releases.json and 302 redirects, exports and scans the site. No users receive upstream URLs. Daily site rebuilds perform the same mirror operation. A stable release must remain within the three retained releases.
8. Site CI calls the deploy hook after passing guards; Cloudflare builds from the same commit with the private read token. Confirm production deployment completion and run the public download/update checks.

The daily healthcheck follows only the site's `/download/notch/` and `/downloads/notch/appcast.xml` URLs. GitHub is used solely to create/comment on the private maintenance issue when they fail.

No public feed exists until hosting is configured and deployed. Do not invent a hostname or publish a QA build. Never overwrite a published versioned artifact. Run the clean-Mac test in TESTING.md before claiming auto-updates work end to end.
