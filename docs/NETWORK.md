# Outbound network inventory

The app's own HTTP requests are limited to:

| Host | Trigger | Data |
| --- | --- | --- |
| Final `SITE_URL` hostname, configured at build time | Sparkle automatic/manual update checks and downloads | Standard HTTP request metadata; the public appcast and signed ZIP. No membership/license requests. |
| `api.open-meteo.com` | Weather enabled, forecast refresh (cached 15 minutes) | Coordinates, units and forecast parameters |
| `geocoding-api.open-meteo.com` | Weather enabled and manual city selected | Entered city, locale language and result limit |

There is no IP-location provider. macOS Location Services are used when authorized; their OS-managed transport is controlled by macOS. Without usable location, enter a city in Weather Settings. Disabling weather cancels app weather work.

Report a Problem opens a mailto draft in the user's email client with app version/build, macOS version and service diagnostics. This may include the app's installation path, city and permission/error summaries. Clipboard contents are excluded. Nothing is sent automatically; the email client/provider contacts its own servers only if the user chooses to send.

The app does not contact private release storage. Sparkle's XML namespace identifier is not a network request. System Settings links are local OS URL schemes. The website's local assets and fonts use the site host; an optional payment-platform link opens only after a user chooses support. CI tooling, source dependencies and private release API calls are build-time infrastructure and are not shipped network clients.

Validation: source URL audit, built Info/Resources/executable guard and signed QA build passed locally on 2026-10-24. Live process-network capture and a two-version update remain unperformed until a production origin is available. See TESTING.md.
