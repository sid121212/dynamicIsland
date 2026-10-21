# Architecture · 0.5.0

## Window and shape

main.swift owns IslandPanel and AppDelegate. IslandPanel is transparent, borderless and non-activating, has no system shadow, and stays at mainMenu + 3 across Spaces and full-screen apps.

The window top is screen.frame.maxY, never visibleFrame.maxY. Its dimensions are expandedSize + 40 in both axes. Position/size change only for a new display geometry, not when the island expands.

NotchSurface.swift owns IslandView and NotchGeometry. The same pure-black concave-top/convex-bottom path is used in every state. A single timed spring samples width, height and both corner radii together. Interrupting the animation starts from the currently displayed geometry. Expanded content retains a fixed coordinate system, is clipped to the path and fades as a composited layer.

The view's path is also the source of truth for hover and click interception. AppDelegate changes ignoresMouseEvents according to the current pointer and path, including during animations. The local click monitor consumes only events delivered to IslandPanel, allowing the popup settings menu to handle its own events.

## Layout

The hardware notch is measured with safeAreaInsets.top and auxiliaryTopLeftArea/auxiliaryTopRightArea. Virtual fallback: 200×32.

Expanded width = min(560, max(500, notchWidth × 2.9)); height = notchHeight + 102. Top row is notchHeight tall, with both tabs before the hardware gap and gear at the right. The 102-point body contains a media column and a flexible calendar column. A disabled camera column reserves no space.

Colors: black background, white text with 55% secondary and 30% disabled opacity, white 7% cards and 14% selected capsules. Today's date uses the system accent. Event bars can use their calendar colors; source icons retain native app colors.

## Data and lifecycle

SystemMonitor.swift owns module preferences and data adapters: CoreAudio, DisplayServices, IOKit, EventKit, CoreLocation/Open-Meteo, Automation for Music/Spotify, and optional in-memory clipboard history. Each adapter is skipped while disabled; weather tasks/location stop on disable, and disabled media ignores in-flight results.

Notify.swift is the small local activity writer invoked by notify.sh. AppDelegate drains its atomic inbox and expires transient activity state.

There is no mirror, secure lock-screen service, or generic notification interception in this version.

## Build and validation

build.sh selects the active SDK with xcrun and keeps module caches inside build/. It compiles SystemMonitor.swift, NotchSurface.swift and main.swift, plus a separate notification helper, then ad-hoc signs the bundle.

run.sh launches the exact current bundle and checks its process path. The obsolete checkout was removed; do not recreate a second application with a conflicting bundle identity.

check.sh builds Tests/main.swift against the production geometry/view and adapters using an isolated preview model. Tests cover state geometry and hit behavior and do not request permissions or read personal data.

The app's --render-previews command exports six 2× states. Tools/compare-previews.swift combines an attached reference screenshot with the expanded render for visual comparison. Preview media metadata is explicitly synthetic. Live UI checks require an unlocked Mac.
