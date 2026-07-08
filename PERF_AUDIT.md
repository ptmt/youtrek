# YouTrek Performance Audit

Self-paced audit loop: one UI area per iteration. Goals: faster initial load,
faster switching between UI states, fewer layout jumps and main-thread freezes.

## Checklist

- [x] 1. App startup / initial load path
- [x] 2. Sidebar + workspace switching
- [x] 3. Issue list
- [x] 4. Issue detail panel
- [x] 5. Issue board view
- [x] 6. Settings window + command palette
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

## Iteration 2 — Sidebar + workspace switching (2026-07-08)

### Findings

1. **All three panes re-rooted on every AppState change.**
   `WorkspaceViewController.render()` fired on every `appState.objectWillChange`
   (any of ~30 @Published properties, incl. sync bookkeeping, detail caches,
   board timestamps) and reassigned `hostingController.rootView` for sidebar,
   main, AND inspector each time — allocating fresh AnyViews, closures, and
   recomputing `visibleIssues` (sort + filter) per tick. During sync bursts or
   a selection click this re-rooted three SwiftUI hierarchies several times per
   second — the main source of workspace jumps.
2. **Toolbar + traffic-light work on the render hot path.**
   Every render called `toolbarController.refresh()` twice and scheduled an
   async `NativeWindowChrome.alignTrafficLights` pass.
3. **UserDefaults.didChangeNotification → full re-render.** Account metadata
   saves (`lastUsedAt` on every sync completion) write UserDefaults, which
   triggered a full three-pane re-root.
4. `SplitViewFullHeightLayoutEnabler` / `ToolbarSidebarToggleHider` in
   RootView.swift scan the entire window view hierarchy per update, but have
   zero usages (dead code from the SwiftUI-shell era) — no runtime cost; left
   for a cleanup pass.

### Fixes (all in `Sources/YouTrek/App/UI/AppKitWindowContentControllers.swift`)

1. Pane roots are now installed **once** as self-observing SwiftUI views
   (`WorkspaceSidebarPaneRoot`, `WorkspaceMainPaneRoot`,
   `WorkspaceInspectorPaneRoot`, each `@ObservedObject`-ing AppState); SwiftUI's
   own dependency tracking replaces controller-driven re-rooting. Search query /
   progress mode / assignee column moved into an observable `WorkspaceUIState`.
2. Toolbar refresh is a separate coalesced subscription (cheap string/icon
   updates only); traffic lights realign only at toolbar install.
3. UserDefaults changes now update only the affected `WorkspaceUIState` flags
   (with distinct-checks) instead of re-rendering everything.

### Verification

- `swift build` clean, `swift test`: 68/68 passed.

## Iteration 3 — Issue list (2026-07-08)

### Findings

1. **Any content change forced a full `reloadData()`.**
   `IssueListReloadPlanner` returned `.full` whenever the issues array differed
   at all — a single edited row (optimistic update, comment timestamp bump)
   flushed every row view and its avatar. Row-level reload existed only for
   unread-flag changes.
2. **Selection stolen on every list refresh.** `AppState.replaceIssues`
   unconditionally re-selected the first row whenever the list content changed.
   When the remote sync landed 1–2s after the cached load, the user's current
   selection (and the open detail panel) jumped back to row 1 — a major
   perceived-stability bug.
3. **Duplicate avatar downloads.** Each visible row with the same assignee
   started its own `URLSession` download until the first one populated the
   cache (N parallel fetches of the same URL on first paint).

### Fixes

1. Planner now diffs per-row when the row ID sequence is unchanged and reloads
   only changed rows; full reload reserved for count/order/column changes.
   Updated/extended planner unit tests.
   (`Sources/YouTrek/App/UI/IssueList/IssueListView.swift`)
2. `replaceIssues` preserves the current single- and multi-selection when the
   selected issues still exist in the new list (refreshing the stored
   `IssueSummary` in place); falls back to first-row selection only when the
   selection is gone. (`Sources/YouTrek/Domain/ViewModels/AppState.swift`)
3. Avatar loads go through a shared in-flight task table keyed by URL.

### Notes

- The backlog item "serial `hasSeenUpdates` actor hop in loadIssues" was
  examined and dropped: it is a LIMIT-1-style store lookup (~1ms) and moving it
  would subtly change first-run read-seeding semantics. Not worth the risk.

### Verification

- `swift build` clean, `swift test`: all suites pass (planner tests updated,
  +1 new test).

## Iteration 4 — Issue detail panel (2026-07-08)

### Findings

1. **Uncached markdown parsing on every render.** `IssueDetailView` re-renders
   on every AppState change (it observes the container via
   `@EnvironmentObject`, which forwards `appState.objectWillChange`). Each
   render re-ran `MarkdownDisplayTextRenderer.attributedMarkdown(for:)` for the
   description AND every timeline comment — a full
   `AttributedString(markdown:)` parse, with a worst-case per-line re-parse in
   `linePreservingAttributedMarkdown`. N+1 markdown parses per AppState tick
   while the panel is open; the dominant detail-panel cost and a freeze source
   for long descriptions.
2. **`customFieldItems` derived three times per render** in the metadata
   section (`hasCustomFields`, toggle label, display rows) — each derivation
   sorts and merges field metadata.
3. **Sequential option loading on selection change.** The `.task` awaited
   projects → status options → priority options one after another before the
   menus became functional.

### Fixes

1. `attributedMarkdown(for:)` results are memoized in an `NSCache`
   (countLimit 256) keyed by source text — parsing is deterministic per input.
   (`Sources/YouTrek/App/UI/Common/MarkdownTextView.swift`)
2. Metadata section computes the display items once per render; removed the
   now-dead `hasCustomFields` / `customFieldsToggleLabel` helpers and an
   unreachable "No custom fields." branch.
3. Projects/status/priority options load concurrently via `async let`.
   (`Sources/YouTrek/App/UI/IssueDetail/IssueDetailView.swift`)

### Verification

- `swift build` clean, `swift test`: 69/69 passed.

## Iteration 5 — Issue board view (2026-07-08)

### Findings

1. **Per-(issue × column) string allocation in match closures.** Every column
   match call re-ran `issue.fieldValues(named:).map { $0.lowercased() }` — for
   a 200-issue board with 6 columns that is thousands of lowercase/array
   allocations per render, and `BoardContentView` observes AppState so the
   board re-renders on every AppState tick.
2. **Derived collections recomputed repeatedly per render.** `groupModels`
   (O(n) swimlane bucketing) was computed ~3× per body evaluation (content,
   header emptiness check, collapse-all state) and `columnDescriptors` ~4×
   (content ×2, width, diagnostics), each with sorts and full-issue scans.
   The diagnostics "Unmatched" column recomputed `baseColumnDescriptors`
   inside its match closure — per issue.
3. Header counts and lane contents were re-filtered inside child views
   (`issues.filter(column.match)` per column per render).

### Fixes (all in `Sources/YouTrek/App/UI/IssueBoard/IssueBoardView.swift`)

1. Board rendering now derives a single `BoardLayout` per body evaluation:
   matchers are value-sets (field mode) or status enums (status mode, exact
   equality preserved), each issue's lowercased field values are computed once,
   and one pass produces column counts, matched/unmatched totals, and
   per-(group, column) issue buckets.
2. Header row and lanes are pure display views over the precomputed layout.
3. Collapse-all/diagnostics helpers take the computed groups/layout instead of
   recomputing them.

### Verification

- `swift build` clean, `swift test`: 69/69 passed.

## Iteration 6 — Settings window + command palette (2026-07-08)

### Findings

1. **Palette base items rebuilt per render.** `issueItems` sorted all issues
   and formatted a `RelativeDateTimeFormatter` label per issue on every body
   evaluation — and the palette re-renders per keystroke plus on every
   AppState tick while open.
2. **Sections computed twice per render.** `resultsList` used `sections`
   while the footer used `flattenedItems` (which recomputed `sections`),
   doubling the sort + fuzzy-filter work.
3. **Fuzzy matcher lowercased query and candidate per (term × token) call.**
4. Settings window (`SettingsWindowViewController`) is a small static AppKit
   form — reviewed, no issues found.

### Fixes (`Sources/YouTrek/App/UI/Common/CommandPaletteDialog.swift`)

1. Issue/board items are cached in `@State`, built once when the palette opens
   and rebuilt only when `appState.issues` / `sidebarSections` change (with an
   in-place fallback so the first frame doesn't flash the empty state).
2. Sections are derived once per body pass and passed to the list and footer.
3. Search tokens are lowercased once at item-build time; the matcher no longer
   lowercases per call.

### Verification

- `swift build` clean, `swift test`: 69/69 passed.

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
