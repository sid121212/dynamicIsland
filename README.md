# Dynamic Island for Mac

A native macOS utility that recreates the Dynamic Island interaction model as a floating desktop overlay using Swift and AppKit.

This project is intentionally lightweight: a single Swift entry point, custom drawing, a floating panel, and a status-bar helper app pattern. It is designed to be easy to understand, easy to extend, and simple to build locally on a Mac.

## Features

- Compact top-center floating island
- Expanded state with custom controls
- Time and date display
- Battery status reporting
- Five-minute timer
- Hover and click interactions
- Menu bar toggle / recenter / quit actions
- Works across Spaces and full-screen apps
- Local build and run workflow with no external dependencies beyond macOS SDK tools

## Architecture

This app follows a straightforward AppKit architecture:

- `NSApplication` starts the runtime
- `AppDelegate` manages the app lifecycle and control surface
- `IslandPanel` creates the transparent floating window
- `IslandView` draws the island and responds to hover/click events
- `IOKit` is used for battery reporting
- `NSStatusBar` provides the menu bar control

The main implementation lives in:

- [Sources/DynamicIslandMac/main.swift](Sources/DynamicIslandMac/main.swift)
- [Resources/Info.plist](Resources/Info.plist)
- [build.sh](build.sh)
- [run.sh](run.sh)

For a deeper breakdown, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- macOS 14+
- Apple Silicon (arm64)
- Xcode Command Line Tools installed

## Quick start

```bash
cd /Users/siddharthmehta/Documents/tools/DynamicIslandMac
./build.sh
./run.sh
```

You can also open the bundle directly after building:

```bash
open "/Users/siddharthmehta/Documents/tools/DynamicIslandMac/build/Dynamic Island.app"
```

## Project structure

```text
DynamicIslandMac/
├── README.md
├── ARCHITECTURE.md
├── build.sh
├── run.sh
├── Resources/
│   └── Info.plist
├── Sources/
│   └── DynamicIslandMac/
│       └── main.swift
└── build/
    └── Dynamic Island.app/
```

## How it works

1. The app starts as an accessory-style app with `LSUIElement` enabled.
2. It creates a borderless transparent panel near the top-center of the active display.
3. It draws the compact island manually using AppKit primitives.
4. Mouse tracking and click handlers expand or collapse the island.
5. A repeating timer updates the clock and other UI state.
6. The menu bar button gives the user quick actions like toggle, recenter, and quit.

## Build behavior

The build process is intentionally simple:

- compile the Swift file with `xcrun swiftc`
- link against `AppKit` and `IOKit`
- emit a Mach-O binary inside the `.app` bundle
- sign the bundle locally for execution

## License

This project is licensed under the MIT License. See [LICENSE](../LICENSE) for details.

## Repository status

This project is intended to be a clean, source-first macOS utility app. Generated build artifacts are ignored via the repo-level `.gitignore` so the source tree stays publishable.
