# Dynamic Island for Mac

A native Swift/AppKit Nook dashboard that grows from the Mac's hardware notch.

## Build and run

Requires Apple Silicon, macOS 14 or later, and Xcode Command Line Tools.

```sh
./build.sh
./run.sh
```

The app is built at `build/Dynamic Island.app`. The launcher starts that exact bundle and verifies its executable path.

## Interface

- A single pure-black shape stays flush with the screen top, with concave upper corners and rounded lower corners.
- Collapsed geometry follows the hardware notch, with a 200×32 virtual fallback.
- Compact activities add 64-point wings on both sides without increasing notch height.
- Expanded width is `min(560, max(500, notchWidth × 2.9))`; height is `notchHeight + 102`.
- The Nook dashboard contains media playback and a seven-day calendar strip. Weather appears when enabled and loaded.
- The Tray tab contains optional in-memory clipboard history. It keeps eight deduplicated text entries and displays three at a time; clicking restores an entry. Disabling it or quitting clears history.
- The gear and menu-bar capsule open module settings, display selection and Launch at Login.
- Hover expansion is intended after 150 ms and collapse after leaving for 300 ms. **Known issue:** pointer-triggered expansion needs a follow-up fix; use Toggle Island meanwhile.

Debug builds expose test activity and timer controls in the Debug menu:

```sh
./build.sh --debug
```

## Permissions and limitations

Music/Spotify metadata and controls use Automation permission. Local Apple Music artwork appears when available; remote Spotify artwork is not downloaded. Calendar uses EventKit and accounts configured in macOS. Weather requests Location when enabled and sends coordinates to Open-Meteo. Disabled modules skip associated sampling; disabling Weather cancels location and network activity.

Volume and brightness changes appear in the island, but Apple's own HUD remains. Brightness uses private DisplayServices and may not support external monitors. Secure Lock Screen rendering, arbitrary notification interception, Bluetooth batteries, Focus integration, camera mirror and simultaneous multi-display islands are not implemented.

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

## Source layout

- `Sources/DynamicIslandMac/main.swift`: app lifecycle, window, menu and input handling.
- `Sources/DynamicIslandMac/NotchSurface.swift`: shape, animation and dashboard drawing.
- `Sources/DynamicIslandMac/SystemMonitor.swift`: module data and lifecycle.
- `Sources/DynamicIslandMac/Notify.swift`: local activity helper.
- `Tests/main.swift`: layout regression checks.

Generated apps, compiler caches and test executables stay under the ignored `build/` directory.
