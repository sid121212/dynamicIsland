# Dynamic Island for Mac · 0.5.0

A native Swift/AppKit Nook dashboard that grows from the hardware notch.

## Build and run

```sh
cd /Users/siddharthmehta/Documents/tools/DynamicIslandMac
./build.sh
./run.sh
```

Apple Silicon and macOS 14 or later are required, with Xcode Command Line Tools installed. The current project is this directory. The obsolete checkout in Documents/DynamicIslandMac was removed.

## Appearance and interaction

The transparent, non-activating hosting window stays pinned to screen.frame.maxY. It is 40 points larger than the expanded shape in each dimension; it does not resize during transitions. One pure-black path changes size and corner radii inside it.

- Idle: exact hardware notch dimensions from safeAreaInsets and auxiliary menu-bar areas; 200×32 virtual notch fallback.
- Compact: notch height with a 64-point wing on each side and an empty hardware-camera gap. Time and battery text are white; charging may use green.
- HUD: volume/brightness symbol in the leading wing and a level bar in the trailing wing.
- Expanded: width min(560, max(500, notchWidth × 2.9)); height notchHeight + 102. A 186×32 notch produces a 539.4×134 dashboard.
- Concave upper radii: 6 points idle/compact, 20 expanded. Convex lower radii: 14 points idle/compact, 26 expanded. No outline. Expanded shadow: black 45%, radius 14, offset 6.
- Expansion reveals fixed-size content after the spring is nearly settled. Collapse fades content before shrinking.
- Hover expands after 150 ms; leaving for 300 ms collapses. Click the idle notch to pin it, or click outside to collapse.
- Nook and Tray tabs both sit left of the camera. The gear on the right opens the module settings menu. Transparent shadow and ear margins do not capture clicks.

The expanded dashboard uses a 44-point media-art square, title/artist, small source badge, thin progress track and plain SF Symbol playback controls. The calendar column shows a seven-day strip and up to two enabled calendar events. Weather appears as a neutral symbol and temperature only after data arrives. No debug controls, loading text or saturated button fills appear in the shipping surface.

## Modules and permissions

Use the gear or capsule menu-bar icon to toggle Now Playing, HUDs, power events, Calendar, Weather and Clipboard History.

Music and Spotify provide track metadata/playback through Automation permission. Local Apple Music artwork is used when available; missing artwork uses a neutral music-note placeholder. Remote Spotify artwork is not downloaded.

Calendar uses EventKit and macOS Calendar accounts, including iCloud and Google accounts configured in System Settings. Permission is requested when enabled. Weather requests location when enabled and sends coordinates to Open-Meteo for conditions.

Clipboard History is off by default. Its Tray page has a Turn On button. Up to eight deduplicated text items remain in memory; three are visible at once. Clicking an entry copies it back. Disabling the module or quitting clears the history. Images and files are not retained.

Disabled modules skip their associated sampling and requests; disabling Weather also cancels location and networking. No location, clipboard or calendar access occurs in the visual preview harness.

## Verification and previews

```sh
./check.sh
"./build/Dynamic Island.app/Contents/MacOS/DynamicIslandMac" --render-previews "$PWD/build/previews"
```

LayoutChecks verifies top-edge anchoring, concave ear hit testing, transparent margins, fixed hosting dimensions, fade-before-shrink ordering, hardware-derived sizes and compact/HUD dismissal. The signed standalone bundle builds successfully.

The preview command writes six states at 2× resolution, with transparent and contrasting-background PNGs. The media preview uses sample metadata, not personal playback data. A side-by-side comparison with the user-supplied Nook reference is in build/previews/reference-comparison@2x.png.

Live mouse, menu and screen placement verification for this version was blocked by the locked Mac; unlock and run ./run.sh to inspect it on the desktop. Offscreen rendering and geometry checks passed.

## Integrations and limits

```sh
./notify.sh "Download complete" "archive.zip is ready" 8
```

The local helper delivers a transient compact activity to the running app. Installed copies also register dynamicislandmac://. The bundle identifier remains local.siddharth.dynamicisland.modern.

Apple's native volume/brightness HUD is not suppressed. Brightness uses private DisplayServices and may not support external monitors. Secure Lock Screen rendering, generic third-party notification capture, Bluetooth-device batteries, Focus integration, camera mirror and simultaneous islands on multiple displays are not implemented. Launch at Login is most reliable after moving the app to /Applications.
