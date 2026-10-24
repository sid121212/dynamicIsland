# Releasing the free, self-signed Mac app

This pipeline uses **no Apple Developer Program, notarization, Homebrew, license server or sponsor check**. Every public app remains free. Sparkle verifies update archives using EdDSA; this does not make the first downloaded app trusted by Gatekeeper. Recipients may need Open Anyway. Never ask them to disable Gatekeeper, strip quarantine globally, or trust our certificate as a root.

## Current public configuration

- Repository: `sid121212/dynamicIsland` (override with `RELEASE_REPOSITORY` for a staging repository).
- Application: `Dynamic Island.app`, arm64, macOS 15+.
- Signing identity: `NotchDev` (or its certificate fingerprint). Public name lives in `release.config.json`; the private key stays in Keychain.
- Sparkle public key: `R5tnNRqzvurYtEoBF+JYYYkGNPW4zPhD8i5c09+rnws=`. Public keys are safe to commit; private keys are not.
- Feed: `https://github.com/sid121212/dynamicIsland/releases/latest/download/appcast.xml`.
- Sparkle 2.10.0 is pinned by `Package.swift` and `Package.resolved`; SwiftPM verifies its binary artifact checksum. `build.sh` copies the macOS framework out of the XCFramework and links `@executable_path/../Frameworks`.
- Release candidate: 0.5.1, build 11. The existing 0.5.0/build 10 test app does not contain Sparkle; it requires a manual install to receive this updater.

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

## GitHub Actions setup

In the app repository, add these Actions secrets yourself through GitHub's secret UI:

| Secret | Value |
| --- | --- |
| `SIGNING_P12_BASE64` | Base64 encoding of the single exported NotchDev identity `.p12` |
| `SIGNING_P12_PASSWORD` | Its export password |
| `SPARKLE_ED_PRIVATE_KEY` | Exact contents of the file exported by `generate_keys -x` |
| `SITE_DEPLOY_HOOK_URL` | Optional Cloudflare Pages deployment hook for the website |

The public key is committed in release.config.json and Info.plist. An optional **Actions variable** `SPARKLE_PUBLIC_ED_KEY` can override it; this is not a secret. The built-in GITHUB_TOKEN supplies release publishing and issue permissions, scoped by each workflow. Never use a private key as a NEXT_PUBLIC variable or upload it as an artifact.

`release.yml` runs on `v*` tags on a disposable macOS runner, selects recent Xcode and uses the preinstalled CMake/GitHub CLI. `ci-release.sh` creates a random-password temporary keychain, imports only that identity, grants the signing tools access, temporarily trusts the self-signed certificate for **codeSign only**, and restores/deletes everything on exit. An `always()` step retries cleanup after cancellation. It refuses to run outside GitHub macOS Actions. Nothing modifies a recipient's trust store. Public repositories can use GitHub's standard hosted runners under its applicable free-use rules; private repositories, larger runners and hosting/bandwidth can have separate costs.

Enable Issues and scheduled Actions in the app repository. `healthcheck.yml` follows redirects with `curl -I -L`, checks the latest stable versioned DMG and appcast for final HTTP 200, and creates or comments on **Download or appcast is broken** on failure. Before the first stable release, a failing healthcheck is expected. GitHub may disable scheduled workflows in inactive public repositories; verify scheduled runs in the Actions UI.

`site-rebuild.yml` handles `release: published` and manual dispatch, skipping betas. Releases created with the built-in GITHUB_TOKEN do not trigger another workflow, so `release.yml` also calls the deploy hook directly after a stable publish. This avoids silently missing website rebuilds. Configure the website host to run its build and use the correct production origin; a hook only requests a rebuild and does not prove deployment succeeded.

## Local build and release

The build flag `NOTARIZED=0` is the default and includes first-launch help. `NOTARIZED=1` compiles that help out; it does not notarize anything. Keep it at 0 for this pipeline. Both variants can be type-checked with `scripts/typecheck.sh` and `NOTARIZED=1 scripts/typecheck.sh`.

1. Edit `Resources/Info.plist`: choose the next semver and a positive integer build larger than **every** earlier release, including betas. Write reviewed `docs/release-notes/<version>.html`. Keep release notes as small HTML fragments, with no remote scripts/resources.
2. Build locally: `SIGNING_IDENTITY=NotchDev ./build.sh`. Run `./check.sh` and the clean-Mac tests in TESTING.md. To package without publishing: `scripts/package-artifacts.sh <version> <build>`. This generates signed-update artifacts using your existing Sparkle key; it does not contact GitHub. Inspect the DMG drag-to-Applications layout.
3. Commit the reviewed source and Package.resolved. Tag that exact commit and push the tag: `git tag -a v<version> -m 'Release <version>'`, then `git push origin v<version>`. This starts the publishing workflow. Do not push a tag until you intend to release.
4. Alternatively, from a clean checkout at an existing pushed release tag, run `SIGNING_IDENTITY=NotchDev scripts/release.sh <version> <build>`. **This command publishes a GitHub release.** `./package.sh <version> <build>` is an explicit publishing wrapper. Never run it just to test packaging.

The script validates semver/integer build, refuses an existing release, requires a clean checkout at the tag, checks monotonically increasing build markers from prior GitHub releases, builds/signs, verifies the signature and prints the identity. Legacy unmarked releases must be audited manually before the first use; build 11 is greater than our prior local build 10. It never edits or replaces old release assets.

Artifacts under `dist/<version>/`:

- `DynamicIsland-<version>.dmg` and its `.dmg.sha256` sidecar, for people.
- `DynamicIsland-<version>.zip`, created by `ditto -c -k --sequesterRsrc --keepParent`, for Sparkle.
- `appcast.xml` and `DynamicIsland-<version>.html` release notes.

`generate_appcast` signs the ZIP, embeds the reviewed HTML notes and records a versioned GitHub download URL. It reads the local Keychain by default; in CI `--ed-key-file -` receives the exported secret through stdin. Validation rejects missing signatures, key mismatch, wrong version/build/URL, empty archives or missing notes before any upload. A separate CryptoKit verifier checks the actual ZIP signature against the public key in the shipped app and compares the recorded byte length. The DMG is kept out of the appcast input folder, so Sparkle selects the ZIP only. Deltas are disabled initially; a fresh full-update feed is enough for all older supported builds.

A draft release receives all assets first, then is published. Any semver pre-release suffix (including `-beta` and `-beta.1`) is marked pre-release and `latest=false`, so GitHub's `/releases/latest/` stays on stable. Stable releases are explicitly marked latest. A failed upload leaves a draft for inspection; do not delete/retry automatically without checking what exists. If local packaging fails, inspect/remove only its generated `dist/<version>/` folder before retrying.

The script prints the website's version, size in bytes and SHA-256. The website in `../zero-dollar-labs` selects the versioned DMG by prefix and rebuilds its metadata. Keep its Notch status at testing until clean-Mac release acceptance passes, then set released. No Homebrew cask is configured. Release links and SHA-256 must remain beside the first-launch help.

## References

- [Sparkle setup and keys](https://sparkle-project.org/documentation/)
- [Sparkle publishing and archive formats](https://sparkle-project.org/documentation/publishing/)
- [Sparkle nested helper signing](https://sparkle-project.org/documentation/sandboxing/)
- [GitHub events triggered by GITHUB_TOKEN](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow)
