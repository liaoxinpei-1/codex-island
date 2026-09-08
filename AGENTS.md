# Codex Island source repository

## Directories and cleanup
- `Sources/`: macOS application and shared core implementation.
- `Tests/`: focused core and native presentation regression tests.
- `resources/`: application metadata; `scripts/`: build and icon generation tools.
- `plugin/`: optional Codex integration; it is not required to run the native app.
- `.build/`: disposable Swift build intermediates. `dist/`: generated app bundles for this standalone checkout. Never commit either directory, signing credentials, local settings, or runtime data.
- Use lower-case hyphenated script and directory names; Swift types use UpperCamelCase. Stop only task-owned helper processes and preserve unrelated work.

## Implementation and validation
- Target macOS 14 or later using AppKit and SwiftUI. Keep dependencies minimal.
- Keep the physical notch clear, center the compact header on it, and place expanded controls below the menu bar and hardware safe area. External/floating layouts stay inside the visible frame.
- Use read-only IPC snapshot schema v11 and a read-only SQLite catalog for task state. Subscribe/unsubscribe only; reject unsupported snapshot versions. Do not modify the Codex client, database, credentials, approval state, execution ownership, or settings.
- Read quota with a short-lived App Server helper using only initialize/initialized and account/rateLimits/read. Never start turns, change authentication, purchase credits, or consume resets. Discard raw replies and stderr; retain only quota windows and fetch time. Clean up owned helpers.
- Show unavailable or stale state honestly; never invent live tasks. Read pet assets from the user's own installed client rather than redistributing them.
- Run the smallest meaningful checks for the change. Report verified behavior and unverified boundaries separately.
- App packaging requires the builder's valid Apple Development or Developer ID Application identity. Never silently replace a usable identity with ad-hoc signing. Verify the resulting signature. Distribution signing and notarization are separate from local build success.
