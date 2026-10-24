# Release acceptance on a clean Mac

Use an Apple Silicon Mac with macOS 15+ or a clean VM, a fresh user account and default Gatekeeper settings. Do not install the NotchDev certificate or trust it on the recipient. Never disable Gatekeeper or remove quarantine to make a test pass. Intel is unsupported in this pipeline and must not be advertised.

## Before sharing

- Run `scripts/typecheck.sh` and `NOTARIZED=1 scripts/typecheck.sh` against the pinned Sparkle dependency. Run `./check.sh`, plus `python3 Tests/test_release_pipeline.py` and `python3 Tests/test_healthcheck.py`.
- Build using the real NotchDev identity. `codesign --verify --deep --strict --verbose=2 'build/Dynamic Island.app'` must pass. Inspect `codesign -dv --verbose=4` for the app and Sparkle helpers: all must use the same certificate. Confirm arm64 and the framework rpath with `file`/`otool`.
- Verify the packaged app's CFBundleVersion, CFBundleShortVersionString, SUFeedURL, SUPublicEDKey, automatic-check flag and 86400-second interval. Never ship literal placeholders.
- Check the appcast ZIP enclosure uses the versioned site URL and has a nonempty EdDSA signature. Confirm release notes are embedded, file length matches the ZIP and the public key matches the signing key. Compare the DMG sidecar with `shasum -a 256`.

## Clean first installation

1. Download the DMG with a real browser from the site so normal quarantine is applied. Record Mac/macOS version and the exact release/build.
2. Verify its checksum against the site-hosted sidecar. Open the DMG and inspect the app + Applications drag target and Install.txt. Running from the DMG must show “Move to Applications”, offer Reveal in Finder, and quit without starting Sparkle. Test the `/AppTranslocation/` guard too if macOS translocates the bundle.
3. Drag the app into Applications, eject the DMG and try opening it. If blocked, use System Settings → Privacy & Security → Open Anyway, authenticate and confirm. Record the actual wording and behavior; do not assume every macOS version offers exactly the same options. If it cannot open under supported default settings, stop and record the failure rather than weakening protections.
4. Once macOS allows execution, the first-launch help window appears with three steps and screenshot placeholders. The help cannot appear before the OS permits execution; Install.txt and the website cover that earlier stage. Close/Continue, then check the permission window appears. Quit/reopen: help must not repeat for that user. For a NOTARIZED=1 test build, it must be absent.
5. Check the menu bar, notch UI, weather, clipboard, calendar, media helpers and existing app permissions still work. No account, sponsors or license status is requested. Test Launch at Login only after copying to Applications.

## Two-version update test

Use an isolated staging site origin configured via SITE_URL, with the same NotchDev certificate and existing Sparkle key. Both builds must embed that site's feed URL. Never repoint production to experimental builds.

1. Install updater-enabled build N from a browser-downloaded DMG in Applications. Create sample clipboard/tray data and settings. Record permission states.
2. In Update Settings, turn Check automatically off. Quit/reopen; it must stay off. Manual Check for Updates… must still work. Turn it on again and confirm the preference persists. Check startup/feed requests or logs to verify checks use the intended appcast, not a membership endpoint.
3. Publish stable N+1 (greater integer build and semver) with complete assets. Check the latest DMG/appcast with the healthcheck URLs. On N, choose Check for Updates…; read notes, install and relaunch. Confirm N+1's actual bundle/build and signature. No manual reinstall should be needed.
4. Verify user data and settings are retained. Inspect Accessibility, Input Monitoring, Calendar and Location behavior. Record any permission re-prompts; a stable self-signed certificate is helpful but does not guarantee TCC continuity. Do not reset TCC automatically.
5. Publish a newer beta as a pre-release. `/downloads/notch/appcast.xml` must still resolve to the stable feed. A normal N/N+1 app must not offer the beta. Then publish the next stable build with a still-greater integer counter and verify it is offered.
6. In staging only, corrupt a copy of an update archive after signing or use a different signing key. Sparkle must reject it and keep the old app usable. Test a missing appcast, 404 ZIP, lost network and canceled update: the installed app must remain usable. Restore the known-good feed.
7. Test update replacement in `/Applications` and, if supported, `~/Applications`, including a non-admin user and any expected authorization prompt. Record failures rather than claiming blanket silent updates. Update from a read-only/translocated location must be blocked by our startup guard.

## Pipeline checks

- A missing or ad-hoc identity must fail before replacing the existing built app. A malformed/empty public key must fail. Wrong private/public key pairing must prevent publishing, not merely print a warning.
- In a staging repo, run the tag workflow and verify temporary keychains and imported trust are cleaned up on success and failure. Inspect artifacts/logs for accidental secrets; none may be published.
- Test healthcheck against good URLs and a controlled broken URL. It must reuse the exact issue title instead of creating duplicates. Do not deliberately break production URLs.
- Confirm the deploy hook rebuilds the website after a stable release, including releases made with GITHUB_TOKEN. The website's displayed version/size/checksum must match the DMG, and links must work without a login or support prompt.
- No `brew install` instruction should appear for Notch. First-launch help, SHA-256 and local release notes must be reachable from the download area on mobile and desktop.

## Record results

Save release/build, Mac hardware, macOS version, observed result, screenshots and relevant updater logs under `build/acceptance/<version>/` or an approved external test record. Redact private user data. Mark each manual item pass/fail/not run. Compiler and signature checks alone do not prove clean-Mac installation or a two-version update. Do not describe those manual checks as complete until performed.

## Required self-hosted acceptance test (pending)

Use a clean Mac or VM with no signing identity trusted. The following test has **not** been performed; no production domain is configured yet.

1. Configure the final site origin in both repos and hosting. Publish stable v1.0.0 with a new increasing build counter. Wait for the dispatch-triggered site deployment to finish.
2. Visit the site. Download via `/download/notch/`; inspect the 302 and final same-origin DMG. Compare its SHA-256 sidecar. Confirm no browser request or link uses a forbidden host, and verify public appcast/ZIP are same-origin and under 25 MiB.
3. Mount the DMG. Opening from `/Volumes/` must show the Move to Applications guard. Drag into Applications, unmount, then follow Open Anyway in System Settings → Privacy & Security. Never disable Gatekeeper globally.
4. Open the installed app. Confirm first-launch help appears once, manual Check for Updates works, and the automatic-check setting persists. Open Report a Problem and review the mail draft; nothing sends itself.
5. Publish v1.0.1 with a larger build counter and the same signing identity/EdDSA key. Wait for the site deployment. Confirm Download, product metadata, changelog, checksum and SoftwareApplication downloadUrl reflect v1.0.1.
6. In v1.0.0, Check for Updates, install v1.0.1 and confirm replacement/relaunch plus persisted preferences. Verify the installed signature. Repeat with automatic checking enabled; disable it and confirm polling stops.
7. Capture process network activity during checking/downloading with weather disabled: only the site host is permitted. With weather enabled, only that host plus api.open-meteo.com and geocoding-api.open-meteo.com are permitted. Test weather without Location permission: it must ask for a city and never use an IP-location service.
8. On an isolated test feed, verify a tampered ZIP is rejected and beta publication does not replace the stable feed. Verify a >=25 MiB fixture fails packaging and site mirroring with a size message.
9. Confirm Download/cache/noindex headers in the real hosting response and that missing token, missing sidecars and unavailable private releases fail the build without deploying partial files. Record versions, URLs, timestamps and capture evidence.
