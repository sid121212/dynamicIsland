# Dynamic Island for Mac

A native Swift/AppKit Home dashboard that grows from the Mac's hardware notch.

## Build and run

Requires Apple Silicon, macOS 15 or later, current Xcode Command Line Tools (Swift 6.2+) and CMake from its official distribution. The media adapter source is vendored; SwiftPM resolves the pinned Sparkle dependency. No Homebrew is needed.

```sh
./build.sh
./run.sh
```

The app is built at `build/Dynamic Island.app`. The launcher starts that exact bundle and verifies its executable path.

Open **Diagnostics…** from the menu bar to inspect live service health and **Permissions…** to request access for enabled modules. To open Diagnostics immediately and save its status while visible:

```sh
./run.sh --diagnostics --diagnostics-report "$PWD/build/diagnostics.json"
```

Self-signed releases use the existing `NotchDev` identity and Sparkle 2. No paid Apple Developer account, notarization or Homebrew is required by the pipeline. Builds fail if the configured identity or public update key is missing. See [Releasing](docs/RELEASING.md) for signing, backups, CI secrets and publication, and [Testing](docs/TESTING.md) for clean-Mac and two-version update acceptance. Permission persistence still needs manual verification; builds never reset TCC.

## Install from a DMG

```sh
SIGNING_IDENTITY=NotchDev ./build.sh
scripts/bootstrap-release-tools.sh
scripts/package-artifacts.sh 0.5.1 11
```

This creates a verified release disk image at `dist/0.5.1/DynamicIsland-0.5.1.dmg`, containing the app and an Applications shortcut. Quit the running development app, open the DMG, drag the app into Applications, and open it from Applications. Eject the DMG after copying. The app has no Dock icon; use its capsule menu-bar icon.

The build is self-signed with NotchDev, not Apple-notarized. If macOS blocks the first launch, approve the locally built app through Finder's Open command or System Settings → Privacy & Security. Enable Launch at Login after installing the app in Applications.

## Sharing with other users

The DMG is a self-contained app bundle for Apple Silicon Macs (M1 or later) running macOS 15 or newer. Recipients do not need this repository, REA, Xcode, Homebrew, or CMake. They copy the app into `/Applications`, launch it, and grant permissions for the modules they enable. Launch at Login is optional. Each user has their own settings and local Clipboard history; packaging does not include your clipboard history or permissions.

This build does not run on Intel Macs or Windows PCs. Intel support requires rebuilding the app and every bundled native helper/framework for x86_64 (or a universal build), then testing on Intel hardware. Windows requires a separate implementation.

The updater-enabled release candidate is 0.5.1 (build 11). It is self-signed, not notarized, and must pass the clean-Mac tests before a stable public release. Gatekeeper approval remains a first-install step; Sparkle's EdDSA verification protects subsequent update archives. Packaging and creating source files do not publish a release. Only the tagged release workflow or explicit publishing command does that. Complete `docs/TESTING.md` before publishing.

## Interface

- A single pure-black shape stays flush with the screen top, with concave upper corners and rounded lower corners.
- Collapsed geometry follows the hardware notch, with a 200×32 virtual fallback.
- Compact media/activities add 64-point wings per side; volume/brightness HUDs use 72-point wings. Both retain notch height.
- Expanded width is `min(560, max(500, notchWidth × 2.9))`; height is `notchHeight + 102`.
- The Home dashboard contains media playback and a seven-day calendar strip. Calendar shows permission actions until full access is granted, then up to two events with all-day events first. Clicking an event opens Calendar.
- Weather appears as a top-row chip between the camera and gear when enabled and loaded. Click it or choose Weather Settings… to configure a city; automatic mode uses granted Location access or approximate IP location. Current and daily high/low data come from [Open-Meteo](https://open-meteo.com/en/docs), with a 15-minute cache and local temperature units. The chip hides offline.
- Clipboard keeps persistent text, images, screenshots and copied files as horizontal cards. Use All/Images/Text/Files to filter; click a card to copy it, then use Command-V in the destination app. Hover for copy/pin/delete; Space or double-click opens Quick Look. Drag cards out as files, or use the context menu to Save/Reveal. Clear preserves pinned items; Clear All History in Clipboard Settings removes pins too.
- Enable Clipboard History and Screenshots in Clipboard in the menu or Clipboard Settings. Screenshot capture leaves originals intact and shows a 2.5-second Saved activity; click it to open the item. History lives under `~/Library/Application Support/Dynamic Island/Tray/`, survives pause/relaunch, and defaults to 24-hour retention for unpinned items. Settings offer 1 hour, 24 hours, 7 days or never; limits are 100 unpinned items, 25 MB per image and 500 MB overall.
- Controls is the third tab (sliders icon to the right of the camera when weather is present). It contains brightness/volume sliders, percentages and device names, with drag/scroll adjustment, speaker-click mute, press feedback and quarter-level haptics. The Controls menu toggle hides the tab.
- The gear and menu-bar capsule open module settings, display selection and Launch at Login.
- Hover expansion is intended after 150 ms and collapse after leaving for 300 ms. An 8-point hover margin below the camera makes it reachable without capturing outside clicks. Pointer behavior awaits manual review; Toggle Island remains available.

Debug builds expose test activity and timer controls in the Debug menu:

```sh
./build.sh --debug
```

## Permissions and limitations

Now Playing uses the bundled MediaRemote Adapter stream for system-wide metadata, artwork and commands. It runs a startup self-test, keeps paused metadata, and retries stream exits with bounded backoff. If unavailable, Music/Spotify distributed notifications and Automation provide a limited fallback. Progress updates run only while media is visible. See About for dependency credits and `Vendor/README.md` for the pinned source and license.

Calendar uses EventKit and accounts configured in macOS. Location access is requested only through Allow Location… or Permissions. Weather sends coordinates to Open-Meteo; if no usable Location fix is available, choose a city in Weather Settings. No IP-location service is used. Calendar/Weather services stop their observers, timers and requests when disabled. Calendar, Weather and Controls/HUD checks passed user review; Tray image/screenshot capture and previews passed user review; its action and relaunch checks remain pending. See `MILESTONES.md`.

The media-key tap requires Accessibility and Input Monitoring. It suppresses native volume/brightness HUDs only after a supported device write succeeds; failed/unsupported keys pass through. Without grants, Diagnostics reports observe-only mode and the native HUD may also appear. The user confirmed the Controls/HUD manual gate. Brightness uses private DisplayServices for the selected built-in display; external displays show “Not available on this display.” Brightness polling runs only while Controls/HUD is visible; CoreAudio listeners track volume.

The Tray header has clipboard and camera switches: bright means enabled, dim means paused. Image and screenshot cards show previews, including images copied as Finder files.

Clipboard capture ignores concealed/transient/generated data and password-manager app IDs by default. Exclusions are editable in Clipboard Settings. System clipboard denial appears in Diagnostics and links to Privacy & Security; the app does not override it. Screenshots may require Files & Folders access to the configured screenshot folder. Pausing capture does not erase history. Optional recording import and drop-in capture remain P2. Secure Lock Screen rendering, arbitrary notification interception, Bluetooth batteries, Focus integration, camera mirror and simultaneous multi-display islands are not implemented.

Launch at Login is most reliable with the app in `/Applications`.

## Script integration

```sh
./notify.sh "Download complete" "archive.zip is ready" 8
```

The arguments are title, subtitle and duration in seconds. A local helper delivers an atomic inbox message to the running app. Installed copies also register `dynamicislandmac://`.

## Checks

```sh
./build.sh
./check.sh
```

Checks cover hardware-derived sizes, concave-ear hit testing, transparent margins, a fixed hosting window, transition ordering, and compact/HUD dismissal. They use an isolated model without reading personal data or requesting permissions.
Media checks also cover split NDJSON records, microsecond units, diff merging, paused progress and clearing empty payloads. Passing these checks does not establish the manual playback acceptance tests.
Tray checks use temporary storage and a private named pasteboard to test persistence, limits, retention, privacy exclusions, image conversion, screenshot timing and shutdown. The macOS sandbox may block that pasteboard; run these locally with desktop access. No test reads the general clipboard or your Desktop.

## Source layout

- `Sources/DynamicIslandMac/main.swift`: app lifecycle, window, menu and input handling.
- `Sources/DynamicIslandMac/NotchSurface.swift`: shape, animation and dashboard drawing.
- `Sources/DynamicIslandMac/SystemMonitor.swift`: module data and lifecycle.
- `Sources/DynamicIslandMac/CalendarService.swift`: authorization, event changes and daily scheduling.
- `Sources/DynamicIslandMac/WeatherService.swift`: location/city resolution, forecasts, cache and network lifecycle.
- `Sources/DynamicIslandMac/WeatherSettings.swift`: manual city and weather status window.
- `Sources/DynamicIslandMac/VolumeService.swift`, `BrightnessService.swift`, `MediaKeyTap.swift`: level services and guarded media-key interception.
- `Sources/DynamicIslandMac/LevelSliderView.swift`: native Controls sliders and interactions.
- `Sources/DynamicIslandMac/TrayStore.swift`: background storage, dedupe and retention.
- `Sources/DynamicIslandMac/ClipboardMonitor.swift`, `ScreenshotWatcher.swift`: capture lifecycles and diagnostics.
- `Sources/DynamicIslandMac/TrayView.swift`, `TraySettings.swift`: cards, Quick Look, drag-out and settings.
- `Sources/DynamicIslandMac/Notify.swift`: local activity helper.
- `Tests/main.swift`: layout regression checks.

Generated apps, compiler caches and test executables stay under the ignored `build/` directory.

## Auto-updates

Check for Updates… and Update Settings… live in the menu bar. Automatic checks default to once a day and can be turned off. Apps started from a DMG or AppTranslocation show a Move to Applications alert and quit before the updater starts. The unnotarized first-launch guide is shown once per user. No membership or license service is called. See docs/RELEASING.md for the free GitHub release pipeline.


## Brand, tabs and legal notices

The native tab titles are defined together in TabTitles.all: Home / Clipboard / Controls. The website demo has the matching TabTitles constant; keep those values aligned when changing labels. Internal persistence keys, app identity, existing download filenames and Sparkle feed paths are unchanged. Support Notch opens the tool’s #support section; Suggest a Feature opens the site Community page. Problem reports remain editable mail drafts with diagnostics.

LICENSE.txt is a DRAFT Freeware License (zdl-freeware-1.0), with governing law and liability review TODO. Have it reviewed before relying on it. Build-time notices collect SwiftPM checkout license files plus the maintained Sparkle/adapter/Open-Meteo inventory in Resources/third-party-components.json. Full third-party terms remain applicable. Every app bundle and DMG root must contain LICENSE.txt and THIRD-PARTY-NOTICES.txt; packaging verifies the finished mounted DMG as well.
