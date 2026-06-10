# YouTrek

YouTrek is a native YouTrack client for macOS, with an experimental mobile target and a built-in command line interface. The app focuses on fast issue triage, offline-friendly caches, board/saved-search navigation, issue editing, attachments, comments, and local todo lists.

## What Is In This Repository

- `YouTrek.xcodeproj` is the primary project file. It is checked in and should be kept up to date when source files are added.
- `Sources/YouTrek` contains the macOS app, shared domain/data layers, sync, persistence, networking, auth, support services, and CLI entrypoint.
- `Sources/YouTrekMobile` contains the mobile app target.
- `Tests/YouTrekTests` contains unit tests for the shared app logic.
- `docs/` contains deeper notes for architecture, YouTrack API usage, database shape, CLI behavior, and AI-related ideas.
- `landing/` contains the static marketing page assets.

## Current Capabilities

- Three-pane macOS issue workflow with sidebar, issue list, and detail inspector.
- YouTrack saved searches and agile boards, including cached/offline views.
- Issue detail editing for status, priority, assignee, project, and custom fields.
- Parent/sub-issue sections, timeline comments, attachments, and markdown rendering with inline images.
- New issue composer with project/assignee picking and attachment upload support.
- Local todo lists with markdown editing and issue-link styling.
- SQLite-backed local cache for issues, details, saved searches, boards, and mutation state.
- Sync coordinator and operation queue for network refreshes and optimistic/local updates.
- Manual token setup and OAuth/AppAuth plumbing.
- Built-in CLI that reuses the same app executable and data/networking layers.

## Build And Run

Open `YouTrek.xcodeproj` in Xcode and run the `YouTrek` scheme for the macOS app.

From Terminal:

```sh
./youtrek.sh
```

`youtrek.sh` builds the `YouTrek` scheme with `xcodebuild`, places DerivedData under `build/DerivedData` by default, and opens the debug app.

To build without launching:

```sh
xcodebuild -scheme YouTrek -configuration Debug -destination 'platform=macOS' build
```

The repository also includes a `YouTrekMobile` scheme for the mobile target.

## CLI

The CLI is implemented inside the same macOS app executable. Pass arguments to `youtrek.sh` to build and invoke the debug binary:

```sh
./youtrek.sh auth status
./youtrek.sh auth login --base-url <url> --token <pat>
./youtrek.sh issues list --query 'project: ABC sort by: updated desc' --top 20
```

Current command surface:

```text
auth status
auth login --base-url <url> --token <pat>
auth list
auth switch --id <uuid>
issues list [--query <ytql>] [--saved <name>] [--top <n>] [--offline] [--json]
issues comment --id <id> --text <text> [--json]
issues statuses --project <id|shortName|name> [--fields <fields>]
agile-boards list [--favorites] [--offline] [--json]
agile-boards show --id <id> [--sprint <name> | --backlog] [--top <n>]
agile-boards show --name <name> [--sprint <name> | --backlog] [--top <n>]
saved-queries list [--json]
install-cli [--path <path>] [--force]
```

Use `./youtrek.sh install-cli` to install a `youtrek` alias for the app executable.

## Repository Layout

```text
Sources/YouTrek/
  App/              macOS app entrypoint, windows, menus, SwiftUI/AppKit UI
  CLI/              command line dispatch, output formatting, command handlers
  Data/             YouTrack networking, auth, SQLite stores, sync queue
  Domain/           models, repositories, view models
  Infra/            logging, telemetry, app container, keychain/config support
  Assets.xcassets/  macOS assets

Sources/YouTrekMobile/
  App/              mobile app bootstrap and root view
  Assets.xcassets/  mobile assets

Tests/YouTrekTests/
  shared logic tests
```

## Useful Docs

- `docs/ARCHITECTURE.md` - original architecture direction and implementation notes.
- `docs/YOUTRACK.md` - YouTrack REST API notes and query examples.
- `docs/DB.md` - current SQLite table layout.
- `docs/CLI.md` - CLI design and command surface.
- `docs/AI.md` - AI integration notes.
- `docs/SMALL.md` and `docs/IDEAS.md` - smaller product/implementation notes.

## Development Notes

- Add new source files to `YouTrek.xcodeproj/project.pbxproj`; the Xcode project is not generated from `project.yml`.
- Prefer focused tests for parser, persistence, sync, and domain behavior.
- For UI-only changes, build the app and validate the relevant flow manually or through accessibility inspection.
- The package manifest mirrors the shared code/dependencies, but the Xcode project is the main day-to-day build path.
