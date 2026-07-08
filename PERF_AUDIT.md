# YouTrek Performance Audit

Self-paced audit loop: one UI area per iteration. Goals: faster initial load,
faster switching between UI states, fewer layout jumps and main-thread freezes.

## Checklist

- [x] 1. App startup / initial load path
- [ ] 2. Sidebar + workspace switching
- [ ] 3. Issue list
- [ ] 4. Issue detail panel
- [ ] 5. Issue board view
- [ ] 6. Settings window + command palette
- [ ] 7. Sync coordinator / AppState invalidation churn
- [ ] 8. Final verification pass

## Iteration 1 — Startup / initial load (2026-07-08)

### Findings

1. **SQLite open + migrations on the main thread, pre-window.**
   `IssueLocalStore`, `IssueBoardLocalStore`, `SavedQueryLocalStore` are actors,
   but their non-async inits ran on the caller's executor — the MainActor inside
   `AppContainer.live`, which executes during app-delegate init before
   `application.run()`. Each init did directory creation, a legacy-DB copy
   check, `Connection()` open, and ~6–15 migration statements (CREATE TABLE +
   PRAGMA table_info per column). Three stores ⇒ 3× that cost before the first
   frame.
2. **Four sequential disk loads gating first sidebar render.**
   `AppContainer.bootstrap()` awaited drafts → boards → saved queries → todo
   lists one after another; the sidebar only renders after all four.
3. **Synchronous keychain reads in container init.**
   `refreshAccounts()` → `loadAccounts()`/`activeAccountID()` each call
   `refreshSyncedMetadataIfNeeded()`, doing ~4 `SecItemCopyMatching`
   (synchronizable-item) round-trips on the main thread pre-window.

### Fixes

1. Lazy `database()` accessor in all three stores — SQLite open + migration now
   happens on each actor's own executor on first use (during `bootstrap()`, off
   main, and in parallel across the three stores).
   Files: `Sources/YouTrek/Data/DB/IssueLocalStore.swift`,
   `IssueBoardLocalStore.swift`, `SavedQueryLocalStore.swift`.
2. `bootstrap()` uses `async let` to run the four cached loads concurrently.
   File: `Sources/YouTrek/Infra/Support/AppContainer.swift`.
3. Container init now reads accounts from the UserDefaults cache only
   (`cachedAccounts()` / `cachedActiveAccountID()`), and reconciles
   keychain-synced metadata in a detached utility task
   (`scheduleAccountKeychainReconcile`). `KeychainStorage` marked `Sendable`,
   `AppConfigurationStore` marked `@unchecked Sendable` (UserDefaults is
   thread-safe but not Sendable-annotated in the current SDK).

### Verification

- `swift build` clean, `swift test`: 68/68 passed.
- Startup phases are already os_log-instrumented ("Startup:" /
  "Startup detail:" in LoggingService.general); before/after wall-clock can be
  compared from Console logs on a real launch.

## Backlog (spotted, not yet fixed — assigned to later iterations)

- `configureIfNeeded()` calls `loadTokenResult` (sync keychain) from a
  MainActor task — post-window main-thread block. → iteration 7.
- `updateActiveAccount(...)` (e.g. `saveInitialIssueSyncCompleted`) performs
  keychain saves synchronously on the MainActor during sync completion —
  micro-hang source. → iteration 7.
- `loadIssues(for:)` awaits `syncCoordinator.hasSeenUpdates()` before the
  cached-issue load — serial actor hop on the selection-switch path.
  → iteration 3.
- `AppContainer` re-broadcasts every `appState.objectWillChange` to its own
  `objectWillChange` (after a yield) — container-wide invalidation on every
  AppState change. → iteration 7.
