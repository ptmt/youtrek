# CLI Capabilities Plan

This app should expose a command line interface that reuses the same networking, auth, and domain logic as the macOS UI. The CLI should be a first-class executable target (not a script) so it can be installed and run as `youtrek` from Terminal.

## Distribution Constraint (Single App Binary)

Because the app is distributed as a single `.app`, the CLI should be **the same executable** as the GUI. The app binary can detect CLI mode (arguments present) and run a command dispatcher instead of launching SwiftUI.

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
- When the CLI writes a token, store it via `ManualTokenAuthRepository` so the macOS app can reuse it.
- Optionally add a **shared keychain access group** so both GUI and CLI can read the same credential if the sandboxed app is enabled.

## CLI Alias Installation (Single Binary)

To run `youtrek` without the full app path, install a **symlink** or **wrapper script** that points to the app executable:

- Preferred (non-sandboxed): `/usr/local/bin/youtrek`
- User-level (no privileges needed): `~/.local/bin/youtrek` or `~/bin/youtrek`

Provide an in-app action or command to install the alias:

- If unsandboxed: create a symlink in `/usr/local/bin`.
- If sandboxed (Mac App Store): install into `~/bin` and prompt the user to add it to PATH.

Example wrapper script content:

```
#!/bin/sh
exec "/Applications/YouTrek.app/Contents/MacOS/YouTrek" "$@"
```

## Command Surface (initial)

- `youtrek auth login --token <PAT>`
- `youtrek auth status`
- `youtrek issues list [--query <ytql>] [--saved <name>] [--top 50]`
- `youtrek issues show <id>`
- `youtrek issues create --project <id> --title <title> [--desc ...] [--priority ...]`
- `youtrek issues update <id> [--title ...] [--status ...] [--priority ...]`
- `youtrek saved-queries list`

## Output Formats

- Default human-readable table (aligned columns).
- `--json` flag for scripts (machine-friendly).

## Implementation Sketch

1. Add a CLI entrypoint (ArgumentParser) inside the app executable.
2. Build a `CLIContainer` that:
   - resolves config and token
   - builds `YouTrackIssueRepository` and `YouTrackSavedQueryRepository`
3. Map each CLI command to repository calls.
4. Add formatting helpers for table/JSON output.
5. Add an "Install CLI alias" action that writes the symlink or wrapper script.

## App Integration Notes

- CLI should **not** depend on SwiftUI or `AppState`.
- Extract any shared logic out of `AppContainer` if needed (e.g., bootstrap/load issues).
- Use the same `IssueQuery`/`SavedQuery` models to avoid duplicated query logic.

## Open Questions

- Should CLI read the GUI app's Keychain token by default, or require explicit token input?
- Is the app sandboxed (Mac App Store) or distributed outside the store?
- Where should we install the alias: `/usr/local/bin` or `~/.local/bin`?
- Do we need an `inbox` command that maps to the "Inbox" saved search when present?
