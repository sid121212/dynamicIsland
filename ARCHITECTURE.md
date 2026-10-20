# Dynamic Island for Mac - Architecture and Run Guide

This document explains what this app is, how it runs, how the build works, and how the code is structured.

## 1) What this project is

This project is a small native macOS utility app that recreates the familiar "Dynamic Island" interaction pattern from iPhone, but as a floating desktop overlay.

It is intentionally lightweight:

- built with Swift
- uses AppKit instead of a large framework
- draws the island manually
- places a floating panel near the top center of the screen
- supports hover, click, timer interaction, and a menu bar toggle

It is not an iOS app, not a web app, and not a heavy Electron app. It is a classic native macOS app built directly against the system frameworks.

---

## 2) What it does at runtime

When launched, the app:

1. creates a transparent floating panel
2. places it near the top-center of the screen
3. draws a compact pill-shaped island
4. expands it on hover or click
5. shows time, battery, and buttons
6. lets you start/stop a five-minute timer
7. exposes a menu bar icon for toggling and quitting
8. keeps itself alive as a utility app instead of a normal app window

The island has a compact state and an expanded state:

- Compact: time + battery
- Expanded: larger panel with date, larger clock, two action buttons

---

## 3) Required environment

This project targets Apple Silicon and macOS 14+.

The app uses:

- Swift compiler (`xcrun swiftc`)
- AppKit
- IOKit
- LaunchServices (`lsregister`)
- macOS system APIs only

It does not need Accessibility or Screen Recording permission.

---

## 4) Step-by-step: how to run it

From the project folder:

```bash
cd /Users/siddharthmehta/Documents/tools/DynamicIslandMac
./build.sh
./run.sh
```

### What `build.sh` does

The build script:

```bash
#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Dynamic Island.app"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos14.0 \
  -O \
  -framework AppKit \
  -framework IOKit \
  "$ROOT_DIR/Sources/DynamicIslandMac/main.swift" \
  -o "$APP_DIR/Contents/MacOS/DynamicIslandMac"

codesign --force --sign - --timestamp=none "$APP_DIR"
```

This means:

- create the `.app` bundle structure
- copy the Info.plist
- compile the Swift file
- link AppKit and IOKit
- output a Mach-O binary inside the app bundle
- sign it locally for execution

### What `run.sh` does

The run script:

```bash
#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_DIR="$ROOT_DIR/build/Dynamic Island.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -x "$APP_DIR/Contents/MacOS/DynamicIslandMac" ]]; then
  "$ROOT_DIR/build.sh"
fi

pkill -x DynamicIslandMac 2>/dev/null || true
for _ in {1..40}; do
  pgrep -x DynamicIslandMac >/dev/null 2>&1 || break
  sleep 0.05
done
"$LSREGISTER" -f "$APP_DIR"
open "$APP_DIR"
```

This means:

- if the app binary is missing, build it first
- kill any old instance
- re-register the app with LaunchServices
- open the `.app` bundle

This is a common macOS trick when launching a custom local app bundle that is not installed to the system app registry.

---

## 5) Project structure

### Root folder

```text
DynamicIslandMac/
├── README.md
├── build.sh
├── run.sh
├── build/
│   ├── Dynamic Island.app/
│   └── macho-evidence.json
├── Resources/
│   └── Info.plist
├── Sources/
│   └── DynamicIslandMac/
│       └── main.swift
```

### Key files

#### `Sources/DynamicIslandMac/main.swift`
This is the main application source file. It contains:

- app lifecycle
- floating panel definition
- island drawing
- click handling
- hover behavior
- timer logic
- menu bar UI
- battery polling

#### `Resources/Info.plist`
This is the macOS app metadata file. It contains:

- display name
- bundle identifier
- bundle executable name
- minimum OS version
- `LSUIElement = true` which tells macOS this is a utility app, not a normal app window

#### `build.sh`
This compiles the project into a `.app` bundle.

#### `run.sh`
This builds if needed and launches the app.

---

## 6) Architecture overview

The app architecture is intentionally simple and centered around a few core objects.

### Main components

#### 1. `NSApplication`
This is the macOS application runtime. It starts the event loop and is responsible for app-level behavior.

#### 2. `AppDelegate`
This object owns the overall app state:

- creates the floating panel
- creates the island view
- sets up the menu bar status item
- observes screen changes
- manages timers
- handles hover / click logic
- positions the panel on the screen

#### 3. `IslandPanel`
This is a transparent, borderless `NSPanel`.

It acts as the floating window container for the island.

Key properties:

- borderless window
- transparent background
- shadow enabled
- level above regular menus
- appears on all spaces
- full-screen auxiliary

This is the actual "glass overlay" UI element.

#### 4. `IslandView`
This is the most important class. It subclasses `NSView` and handles drawing and interaction.

It is responsible for:

- drawing the pill and expanded content
- tracking mouse hover for expansion
- processing clicks
- toggling timer state
- displaying time / date / battery status
- repainting the UI when state changes

### Architectural pattern

The project uses a simple custom UI pattern:

- manual drawing via `draw(_:)`
- event-driven state changes
- timers for animation and refresh
- direct AppKit primitives rather than SwiftUI

So the core pattern is:

- UI = custom drawing
- behavior = timers + tracking areas + click handlers
- app shell = NSApplication + status item + floating panel

---

## 7) Detailed code flow

### App startup

At the bottom of `main.swift`:

```swift
let application = NSApplication.shared
private let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
```

This is the standard AppKit life cycle entry point.

### `applicationDidFinishLaunching`
This is called once the app is ready.

Inside it, the app:

- sets accessory activation policy (`NSApp.setActivationPolicy(.accessory)`)
- configures the floating panel
- configures the menu bar item
- starts a clock timer
- starts a hover-state timer
- installs global and local mouse monitors

### Floating panel setup

```swift
panel = IslandPanel()
islandView = IslandView(frame: NSRect(origin: .zero, size: IslandMetrics.compactSize))
panel.contentView = islandView
positionPanel(size: IslandMetrics.compactSize)
```

This creates the actual overlay and adds the drawing view to it.

### Panel placement

The code computes a top-center position using:

```swift
NSPoint(
    x: screen.frame.midX - size.width / 2,
    y: screen.visibleFrame.maxY - size.height - IslandMetrics.topInset
)
```

This is what keeps the island floating just below the menu bar or notch area.

---

## 8) How hover and click behavior works

### Hover logic

The island view has a tracking area that watches when the pointer enters/exits the island.

When the pointer enters:

```swift
override func mouseEntered(with event: NSEvent) {
    setExpanded(true)
}
```

When the pointer exits:

```swift
override func mouseExited(with event: NSEvent) {
    guard timerEnd == nil, !pinned else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
        guard let self, self.window?.frame.contains(NSEvent.mouseLocation) != true else { return }
        self.setExpanded(false)
    }
}
```

This creates a subtle temporary expansion effect: the island can expand on hover, then collapse if the pointer leaves.

### Click logic

The click handler is in `handleClick(at:)` and it decides whether the tap is:

- a click on the timer button
- a click on the activity button
- a general toggle of the island

If the expanded content contains the timer region, it toggles timer state. If the activity region is hit, it triggers a demo alert. Otherwise it toggles the pinned/expanded mode.

---

## 9) Timer implementation

The timer is implemented with a `Timer` scheduled on the main run loop.

When the user starts the timer:

```swift
timerEnd = Date().addingTimeInterval(5 * 60)
timerTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { ... }
```

Every second, the app checks whether the target end time has arrived. If it has, it:

- clears the timer end
- invalidates the timer
- plays a system beep via `NSSound.beep()`
- refreshes the UI

This is the mechanism behind the five-minute timer.

---

## 10) Drawing system

The island is drawn manually by overriding `draw(_:)`.

Important parts:

- `drawCompact()`
- `drawExpanded()`
- `drawButton(rect:title:color:)`
- `drawText(...)`

The island uses:

- `NSBezierPath(roundedRect:...)`
- `NSColor`
- `NSAttributedString`
- system fonts

This is a direct AppKit drawing approach, not a layout engine or SwiftUI view hierarchy.

### Compact drawing

The compact mode shows:

- local time
- battery percentage in green

### Expanded drawing

The expanded mode shows:

- label "DYNAMIC ISLAND"
- bigger time
- date
- battery status on the right
- two buttons: timer + activity

This is intentionally simple and modular, with room to extend later.

---

## 11) Battery status

The app reads battery data from IOKit via:

```swift
guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
else { return nil }
```

Then it inspects the Power Source description for:

- `kIOPSCurrentCapacityKey`
- `kIOPSMaxCapacityKey`

This converts the raw capacity values to a percent and displays it in the island.

---

## 12) Why the app is called "Dynamic Island for Mac"

It imitates the design language and interaction feel of Apple's Dynamic Island, but it is not actually tied to native iOS dynamic island internals.

Instead, it is a custom macOS equivalent built using public frameworks and custom event handling.

This project is more of a UI prototype / concept reconstruction than a full-featured system integration.

---

## 13) How the app is structured logically

At a glance, the design is:

```text
App lifecycle
    ↓
AppDelegate
    ↓
IslandPanel (floating window)
    ↓
IslandView (draw + click + hover + timer)
    ↓
System APIs: AppKit, IOKit, NSEvent, NSScreen, NSStatusBar
```

That is the core of the architecture.

---

## 14) Build and runtime lifecycle summary

### Build stage

- compile Swift source
- link AppKit + IOKit
- generate executable inside `.app`
- sign it

### Runtime stage

- create app delegate
- create floating panel
- attach island view
- start timers and event monitors
- show the island near the notch/menu bar area
- react to pointer moves and clicks

---

## 15) Current scope and future extensions

The README describes the current version as a first pass and says future improvements could include:

- Now Playing controls
- media metadata
- volume / brightness HUD
- calendar event display
- notifications
- preferences for size and animation

This means the architecture is intentionally modular and ready to expand by adding more panels or view modules later.

---

## 16) Summary

This repo is a compact, native macOS app that recreates the Dynamic Island idea as a floating utility overlay.

The architecture is intentionally simple:

- Swift source file as the main app logic
- AppKit for the UI shell
- custom drawing for the visuals
- event-driven hover/click/timer behavior
- NSStatusBar for menu bar control
- IOKit for battery information

It is not a large framework app; it is a purpose-built custom overlay implementation.

If you want to extend it, the main place to work is:

- `Sources/DynamicIslandMac/main.swift`

If you want to build or run it again, use:

```bash
cd /Users/siddharthmehta/Documents/tools/DynamicIslandMac
./build.sh
./run.sh
```
