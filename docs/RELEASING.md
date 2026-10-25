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


## One-command local releases

The app repository is derived from `git remote get-url origin`; it must be private and different from the website repository. `release/config.sh` owns `SLUG=notch`, `NAME=Notch`, `ASSET_BASE=Notch`. Never use the website repository for app releases.

Initial setup (no Homebrew): install GitHub CLI from its official distribution, run `gh auth login`, then:

```sh
scripts/bootstrap-release-tools.sh
cp .release.env.example .release.env
# Edit SITE_URL, SITE_REPO, CONTACT_EMAIL and optional SIGN_IDENTITY.
```

`.release.env` is ignored. Use the final HTTPS origin without a trailing slash; installed apps depend on `/downloads/notch/appcast.xml` staying stable. Exported environment variables can also supply the configuration. This file contains no token or private key. Set `CONTACT_EMAIL` for editable problem-report drafts. Keep the self-signed certificate and matching Sparkle private key in your login Keychain; the script reads only the public key via `generate_keys -p` and lets Sparkle sign privately through Keychain.

Add reviewed release notes under `## 1.0.0` in `CHANGELOG.md` (or enter them interactively). Review source changes and commit them yourself on main. The script never commits or pushes. Do not create the release tag manually: `gh release create` creates it from the matching remote main commit. Before publication, local HEAD must already be pushed to origin/main so released source matches the built app. A --no-publish dry run can use a clean local commit before pushing.

Normal release (example build 12; always choose a build greater than the latest released build and at least the committed Info.plist build):

```sh
scripts/release.sh 1.0.0 12
```

Dry run / local packaging only:

```sh
scripts/release.sh 1.0.0 12 --no-publish
ls -lh dist/
scripts/verify-release.sh dist/
```

Publish an already verified dist after rechecking every contract rule:

```sh
scripts/release.sh 1.0.0 12 --publish-only
```

Preflight requires clean main, X.Y.Z semver, a positive increasing build, a valid HTTPS origin without trailing slash, signing identity, authenticated gh, a private app repository, existing Sparkle tools, and no local/remote release tag. It reads the latest semver tag's published appcast to find its actual build (source Info.plist may be a build-time template). API failures stop the release. Build 1 is not valid for this repository: its committed baseline is already 11.

Archive old dist contents outside dist before starting a new version; the packager refuses to overwrite or mix artifacts. Every artifact must be strictly under 26,214,400 bytes. Exactly these five files are published:

- `Notch-X.Y.Z.dmg`
- `Notch-X.Y.Z.zip`
- `Notch-X.Y.Z.dmg.sha256` (one line, hex digest, two spaces, DMG filename)
- `appcast.xml` (one item, this version/build only, embedded notes and signed ZIP)
- `release-notes.md`

The app is built arm64, stamped before signing with version/build, macOS 15.0, the current public Sparkle key and the unchanged site feed URL, signed inside-out with NotchDev, and strictly verified. DMG root and app Resources must contain both license files. Verification mounts the finished DMG, parses XML/binary Info.plist from the ZIP, compares its key/feed/version/build, checks the checksum and archive length, and independently verifies EdDSA before publication. The release title is `Notch X.Y.Z`, tag `vX.Y.Z`, published stable (neither draft nor pre-release).

## Website notification and deployment

No macOS Actions build job is needed. `.github/workflows/notify-site.yml` runs on published releases (or manual dispatch) and sends `app-released` to the configured `SITE_REPO`; it requires exactly HTTP 204. App repo secret `SITE_DISPATCH_TOKEN` needs permission to dispatch into the private website repository (fine-grained Contents write); variable `SITE_REPO=owner/zero-dollar-labs`. Keep SITE_URL and CONTACT_EMAIL configured as repo variables for health checks/other app automation.

Site repo secret `RELEASES_READ_TOKEN` has read-only Contents access to each app repository. Site variables include NEXT_PUBLIC_SITE_URL and other NEXT_PUBLIC values; the site-only public key belongs in private build config tools.ts. The site's deploy.yml builds on main push, app-released dispatch, daily schedule and manual dispatch, validates releases and public-host/SEO guards, then deploys using CLOUDFLARE_API_TOKEN (secret) and CLOUDFLARE_ACCOUNT_ID (variable). The site retains three newest stable semver releases under the existing public paths. Visitors never need the private repository.

A failed notifier does not undo a published release. Retry the notifier manually; never rerun publishing for that version. A failed site build keeps the prior deployed website intact.

## Fix-forward and rollback

Never edit or re-upload a published artifact. Bump the patch version and integer build, add reviewed notes, archive old dist, commit and push source yourself, then release again:

```sh
scripts/release.sh 1.0.1 13 --no-publish
scripts/verify-release.sh dist/
scripts/release.sh 1.0.1 13 --publish-only
```

For rollback, manually mark the bad release as pre-release or delete it, then manually rerun the site Deploy website workflow so the public mirror falls back to the previous stable version. Removing a release does not downgrade already-installed apps; publish a fixed version with a higher build for those users. Do not rewrite the feed URL.

The daily healthcheck follows the site's `/download/notch/` and `/downloads/notch/appcast.xml` URLs. No publication/deployment or clean-Mac update is implied by successful local packaging. Complete TESTING.md before claiming installed updates work end to end.
