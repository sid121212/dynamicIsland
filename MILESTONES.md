# Verification checkpoint — 2026-10-23

The requested Parts 1–8 are being implemented in order. Stable NotchDev certificate setup is explicitly deferred by the user; the build remains ad-hoc signed. Do not reset TCC automatically.

## Part 1: Diagnostics and permission onboarding

Build, code signature verification, geometry checks and launch through `open`: PASS.
Live Diagnostics report confirms that missing Calendar, Location, Accessibility and Input Monitoring grants are visible. Brightness and volume reads succeed. Signature remains red because no stable certificate is installed. Screenshot watcher, active event tap and battery notifications accurately remain amber/unimplemented.

The UI automation inventory lists the modern app, but selecting its bundle identifier fails with `Invalid app`; selection by name previously resolved the obsolete identifier. Visual verification of Diagnostics and the Permissions buttons therefore remains pending. No grants were silently approved.

## Part 2: System-wide Now Playing

Bundled adapter builds; startup self-test and live metadata stream: PASS in Diagnostics. A real playing track was observed. Geometry and media protocol regression checks: PASS.

User replied “Perfect” to the requested artwork/source-badge, play/pause and seek check. Current playback manual gate: PASS. The exact browser/Spotify source matrix was not separately reported; do not infer every Part 8 source-specific test passed.

## Part 3: Calendar and Weather

Build, signature verification, launch through `open`, prior regression checks and new Calendar/Weather regression checks: PASS. New checks cover permission-specific actions, all-day event ordering, current/high/low parsing, malformed response rejection, night symbols and weather header geometry.

Live Weather Diagnostics: green, Open-Meteo HTTP 200 with current/high/low data, using approximate IP fallback. User replied “Both pass” to the Calendar event display and Weather chip/settings checks. Part 3 manual gate: PASS. The complete offline/3-second and deny-then-grant matrix was not separately reported.

Calendar and Weather now have separate observable services. Calendar registers event-store/day/timezone/application-activation observers while enabled, fetches every five minutes and at midnight when authorized, and stops observers/timers on disable. Weather cancels tasks/location requests/network monitoring and its 15-minute timer on disable. Manual city settings and automatic location/IP fallback are implemented. Offline weather is hidden; the 3-second launch/offline acceptance check remains pending manual verification.

## Part 4: Controls and media-key HUDs

Build (no compiler warnings), strict signature verification, launch through `open`, prior checks and new Controls/key-policy checks: PASS. Tests cover camera-safe tab placement, slider bounds, key decoding, unsupported-key passthrough, failed-write passthrough, paired releases, mute repeats and Shift-Option fine increments. Offscreen rendering verified dark icons/percentage text over light slider fill.

Live volume Diagnostics was green for MacBook Air Speakers; external DELL brightness correctly unavailable. User replied “Controls and HUDs pass” to the real slider/mute/key test with the built-in display and permission grants. Part 4 manual gate: PASS, including native HUD suppression as reported by the user. Permissions may need re-granting after subsequent ad-hoc builds; stable signing remains deferred.

The Controls tab uses an icon when weather leaves insufficient space for its label, with its full name in the tooltip and menu. Brightness polls at 10 Hz only while Controls/HUD is visible; volume uses CoreAudio listeners. Relative brightness keys sample the current value before changing it. Disabling both consumers stops these services; disabling HUDs removes its event tap and pending HUD work.

Additional lifecycle fixes: two preexisting orphaned adapters were observed and removed only by exact development bundle path. Relaunch verification shows one adapter owned by the current app and no orphan. SIGTERM/SIGINT now route through normal app shutdown. Idle hover reaches an 8-point margin below the hardware camera, while shape-only hit testing keeps outside clicks unblocked; pointer behavior remains part of manual review.

The requested Controls/HUD manual gate is complete.

## Part 5: Persistent Tray

Implemented: background actor storage, text/image/screenshot/file items, SHA-256 dedupe, local copied payloads, 192-pixel thumbnails, private file permissions, 100-unpinned/25-MB-image/500-MB limits, pinning and retention. Clipboard capture polls at 0.4 seconds, ignores concealed/transient/generated types, respects excluded app IDs and its own writes, and checks the real `NSPasteboard.accessBehavior` denial state on macOS 15.4+. Screenshot capture uses Metadata Query plus a folder descriptor watcher with 200-ms stable-size checks. Original files are never deleted by history actions.

Tray cards provide filters, counts, clear-unpinned, hover copy/pin/delete, copied feedback, Quick Look, Save/Reveal and real file URL drag-out. Settings expose pause, screenshot toggle, retention, exclusions and clear-all. Screenshot Saved activities link to the Tray item. Screen-recording poster frames and drop-in hot-zone capture are optional P2 and remain deferred.

Automated fixture checks PASS: dedupe, fresh-instance persistence, pinned/expired/count/byte policies, corrupt-index preservation, TIFF conversion, oversized/malformed image rejection, concealed/excluded/own-write suppression, copied image/file handling, screenshot capture under one second, and capture shutdown. Tests use a private named pasteboard and temporary folders, never the user's general clipboard or Desktop. These desktop API checks need a non-sandboxed local run; the sandbox denied test-pasteboard writes. Offscreen card rendering exposed a `/var` versus `/private/var` cleanup mismatch; paths are now normalized, and tests assert payload/thumbnail survival and readability after reload.

The initial manual Tray check reported missing items/screenshots. After the fixes, the user confirmed “Both appear with previews”: image and screenshot capture/preview manual check PASS. Part 5 remains open for the remaining action and relaunch checks. The report showed three clipboard imports but screenshot capture was disabled. A startup sample also confirmed main-thread folder enumeration blocked the app before launch completed. Folder access now runs in a background task after the UI launches. Follow-up adds capture switches in the Tray header, immediate scroll/mask layout, Finder image previews, and a container-level regression check. Rebuilt and opened: Clipboard Diagnostics green; screenshot capture green (Downloads folder watcher and metadata active); a fresh clipboard file import is observed. Copy/drag/Quick Look/relaunch still require a fresh manual pass before Part 6. Copying a card restores the clipboard; the user pastes it into another app with Command-V. It does not inject keystrokes into other apps.

## Remaining implementation

Part 6 remaining menu polish; Part 7 remaining service extraction. Capture/previews are user-confirmed. Hold at the Part 5 gate for copy/drag/Quick Look and app-relaunch persistence checks.

## Part 8 acceptance status

| Test | Status |
|---|---|
| 1. Rebuild twice and retain grants | BLOCKED: stable signing deferred; permissions not granted |
| 2. YouTube browser metadata and commands | PENDING manual source-specific check |
| 3. YouTube Music/Spotify, including pause | PENDING manual source-specific check |
| 4. Calendar deny/grant and events | Event display manual check PASS; full deny/grant matrix not separately confirmed |
| 5. Top-row weather online/offline | Live fetch and chip/settings manual check PASS; offline/3-second timing PENDING |
| 6. Media keys suppress native HUD | PASS, user reported Controls/HUDs pass |
| 7. Controls sliders and external display | PASS, user reported Controls/HUDs pass; external DELL state also observed |
| 8. Text/image/screenshot capture | Automated tests PASS; user confirmed copied images and saved screenshots appear with previews. Text/timing/Saved activity not separately confirmed |
| 9. Tray copy, drag and exclusions | Automated exclusion/restore checks PASS; actual Notes/Finder interaction PENDING |
| 10. Tray persistence and retention | Automated fresh-store/retention checks PASS; actual app relaunch PENDING |
