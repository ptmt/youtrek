# CLI Capabilities Plan

This app exposes a command line interface that reuses the same networking, auth, and domain logic as the macOS UI. The CLI is built into the app executable so it can be installed and run as `youtrek` from Terminal.

## Distribution Constraint (Single App Binary)

Because the app is distributed as a single `.app`, the CLI is the **same executable** as the GUI. The app binary detects CLI mode (arguments present) and runs a command dispatcher instead of launching SwiftUI.

This allows `youtrek` in Terminal to execute:

```
/Applications/YouTrek.app/Contents/MacOS/YouTrek <cli-args>
```

and avoids shipping a second binary.

## Goals

- Provide fast, scriptable access to YouTrack (list, search, create, update issues).
- Reuse existing domain/data layers to avoid diverging behavior from the app.
- Share configuration (base URL, auth token) with the macOS app.

## High-Level Architecture

- Add a **CLI entrypoint** inside the existing app executable.
- Detect CLI mode early in `@main` and run a CLI dispatcher before SwiftUI loads.
- Keep SwiftUI UI code out of the CLI path; only reuse Domain/Data/Infra.
- Introduce a small CLI container that mirrors AppContainer but without UI state.

Suggested layers:

- **Domain**: models, repositories, query types (already present).
- **Data**: networking and DB (already present).
- **Infra**: configuration store, auth repositories, keychain storage (already present).
- **CLI**: argument parsing + command routing + output formatting.

## Authentication & Config Sharing

- Reuse `AppConfigurationStore` for base URL and token storage.
- Allow explicit overrides via flags or env vars:
  - `--base-url` or `YOUTRACK_BASE_URL`
  - `--token` or `YOUTRACK_TOKEN`
- When the CLI writes a token, store it via `AppConfigurationStore` so the macOS app can reuse it.
- Optionally add a **shared keychain access group** so both GUI and CLI can read the same credential if the sandboxed app is enabled.

## CLI Alias Installation (Single Binary)

To run `youtrek` without the full app path, install a **symlink** or **wrapper script** that points to the app executable:

- Preferred (non-sandboxed): `/usr/local/bin/youtrek`
- User-level (no privileges needed): `~/.local/bin/youtrek` or `~/bin/youtrek`

Provide an in-app action or command to install the alias:

- Because this app is distributed outside the Mac App Store, install a symlink in `/usr/local/bin` by default.
- If permissions are denied, fall back to a user-level path and update PATH manually.

Example wrapper script content:

```
#!/bin/sh
exec "/Applications/YouTrek.app/Contents/MacOS/YouTrek" "$@"
```

## Current Command Surface

- `youtrek auth status`
- `youtrek auth login --base-url <url> --token <PAT>`
- `youtrek issues list [--query <ytql>] [--saved <name>] [--top 50] [--json]`
- `youtrek saved-queries list [--json]`
- `youtrek install-cli [--path <path>] [--force]`

## Planned Commands

- `youtrek issues show <id>`
- `youtrek issues create --project <id> --title <title> [--desc ...] [--priority ...]`
- `youtrek issues update <id> [--title ...] [--status ...] [--priority ...]`

## Output Formats

- Default human-readable table (aligned columns).
- `--json` flag for scripts (machine-friendly).

## Implementation Notes

- CLI entrypoint is wired in `@main` and short-circuits SwiftUI on CLI usage.
- CLI reuses `YouTrackIssueRepository` and `YouTrackSavedQueryRepository`.
- Output supports table and `--json`.
- CLI alias can be installed from Terminal (`youtrek install-cli`) or via the in-app menu: **CLI -> Install CLI Alias**.

## App Integration Notes

- CLI should **not** depend on SwiftUI or `AppState`.
- Extract any shared logic out of `AppContainer` if needed (e.g., bootstrap/load issues).
- Use the same `IssueQuery`/`SavedQuery` models to avoid duplicated query logic.

## Open Questions

- Do we need an `inbox` command that maps to the "Inbox" saved search when present?
