# General

YouTrek is a macOS SwiftUI app. All Design guidelines is in VISUAL_GUIDELINES.md and general architecture in ARCHITECTURE.md
It's three column layout app with rich toolbar. 
- First column is filters and different screen
- Second layout is issue list (cards with minimal information about each issue like title, data, assignee and other — we should decide what fits best)
- Third column is a detail view

Toolbar should contain a separate place for a new issue creation (text input)

Think of Apple Mail and Linear

## Screens

- Main screen for issue list. 
- Settings
- Separate detachable new issue screen
- Separate detachable view/edit issue screen

## Offline-first sync

When app opens, the syncronization should kick on showing a progress bar right behind the toolbar. It should download as much as possible to show the issue list for all filters like "Created by Me" etc.

## Developer Mode (Debug builds)

- Toolbar adds a "Developer" menu in DEBUG builds only.
- "Simulate slow responses" toggles a 5-second delay on every API request.

## Sync UX

- All sync work routes through a single operation queue to keep network operations serialized.
- When the queue is active, the toolbar shows a global "Syncing…" indicator.
- If a local change conflicts with a remote update, show a conflict dialog with a copyable text area so users can preserve their edits.
