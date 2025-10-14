# ARCHITECTURE.md — macOS “Tahoe 26” Issue-Tracker Client (Swift)

---

## 1) App Shell & Navigation

* **Three-column layout:** `NavigationSplitView` for sidebar → list → detail. Supports 2–3 columns and programmatic state restoration. ([Apple Developer][1])
* **List column:** macOS **`Table`** for sortable/multi-select lists (issues). ([Apple Developer][2])
* **Global search:** `.searchable(...)` on the split view or container; command-K to focus. ([Apple Developer][3])
* **Menus & shortcuts:** `commands { CommandMenu(...) }` + `.keyboardShortcut(...)` for New Issue, Assign, Change Status, etc. ([Apple Developer][4])

```swift
@main struct IssuesApp: App {
  var body: some Scene {
    WindowGroup { RootView().environment(AppContainer.live) }
      .commands { AppMenus() }
  }
}
```

---

## 2) Data, Caching & Offline-First

* **GraphQL (preferred):** Apollo iOS with **normalized cache**; add `SQLiteNormalizedCache` for persistence. ([Apollo GraphQL][5])
* **or REST:** Generate a typed client with **Swift OpenAPI Generator** (SPM plugin). ([Swift.org][6])
* **Local store:**

  * **SwiftData** for simple, SwiftUI-friendly persistence, or
  * **GRDB** for full-control SQLite, migrations, observation, and concurrency. ([Apple Developer][7])
* **HTTP cache:** Respect `ETag`/`If-None-Match`. Serve **304** from cache; for writes use `If-Match` and handle **412 Precondition Failed**. ([MDN Web Docs][8])
* **Connectivity:** Gate sync with **NWPathMonitor**; pause/resume on path changes. ([Apple Developer][9])

**Repository pattern**

* UI always reads **local-first**.
* Background tasks refresh from network and merge.
* Mutations are appended to an **operation log** (op-log) with optimistic UI; reconcile on server ACK (retry with backoff; on `412` rebase or prompt merge). ([MDN Web Docs][10])

---

## 3) Realtime Updates

* **WebSockets:** `URLSessionWebSocketTask` (or GraphQL subscriptions via Apollo). Keep a reader loop in a `Task`, decode events, and apply to the store. ([Apple Developer][11])

---

## 4) Auth & Security

* **Flow:** OAuth 2.1 / OIDC **Authorization Code + PKCE** via **ASWebAuthenticationSession** (system browser) with **AppAuth** SDK. Store tokens in Keychain. ([Apple Developer][12])
* **Why this:** ASWebAuthenticationSession gives secure external user-agent; AppAuth maps OAuth/OIDC idiomatically on Apple platforms. ([Apple Developer][12])
* **Scopes & rotation:** Least privilege; automatic refresh; single reauth gate on 401.

---

## 5) Images

* **Nuke** or **Kingfisher** for memory+disk caching, prefetching, transforms. Both are mature, Swift-native. ([GitHub][13])

---

## 6) Logging, Telemetry & Crash Reporting

* **Logging API:** **swift-log** with **OSLog** backend; structured categories; ship at info/warn levels. ([GitHub][14])
* **Crash & performance:** **Sentry Cocoa** (SPM) for crashes, breadcrumbs, traces. ([Sentry Docs][15])

---

## 7) State Management

* Keep it boring: **MVVM** with `@Observable`/`@State` and `@MainActor` view models.
* If you need stricter unidirectional flow and feature isolation, adopt TCA (not mandatory).

---

## 8) Error Handling & Retries

* Centralize networking with retry + jittered backoff.
* Use **idempotency keys** for potentially duplicate POST-like mutations.
* UI policy: toast on success; inline error cells with **Retry / Copy Error**; **offline badge** when `NWPathMonitor` reports `.unsatisfied`. ([Apple Developer][9])

---

## 9) Project Layout

```
App/
  AppMain.swift
  Menus/            # Command menus & keyboard shortcuts
  UI/
    Sidebar/        # Teams, projects, saved filters
    IssueList/      # SwiftUI Table + filters/sort/search
    IssueDetail/    # Markdown editor, timeline, subtasks
    Common/
  Domain/
    Models/         # Issue, Project, User, Label, Comment
    Repositories/   # IssueRepository, ProjectRepository, AuthRepository
  Data/
    GraphQL/        # Apollo client, schema, generated
    REST/           # OpenAPI-generated client
    DB/             # SwiftData or GRDB, migrations
    Sync/           # OpLog queue, backoff, conflict resolution
    Networking/     # URLSession config, WS client
    Auth/           # AppAuth wrapper, token store
  Infra/
    Logging/        # swift-log + OSLog
    Telemetry/      # Sentry
  Tests/
```

---

## 10) Three-Column UX Must-Haves

* **Sidebar:** Workspaces/teams, projects, smart filters, saved searches; persist expansion/selection.
* **List (Table):** Multi-select, inline edits (title/status/assignee), column config per user, infinite scroll, context menu. Use native **`Table`** for macOS sorting & selection. ([Apple Developer][2])
* **Detail:** Markdown editor with live preview, activity timeline (virtualized), subtasks matrix.

---

## 11) Contracts for AI Agents

Define a small, stable surface in your client SDK so agents can act safely:

**Actions**

* `create_issue(title, project_id, labels, assignee_id)`
* `update_issue(id, patch)`
* `add_comment(issue_id, body)`
* `change_status(id, status)`
* `search(query, filters, sort)`

**Invariants**

* Entities have stable `id`, monotonic `updated_at`, and `etag`.
* Mutations send `If-Match: <etag>`; on **412** the agent must **refetch & rebase** (or prompt user to merge). ([MDN Web Docs][16])
* API is defined by **GraphQL schema** or **OpenAPI**; clients are **code-generated** in CI to stay in sync. ([Apollo GraphQL][5])

---

## 12) Implementation Order (fastest to something useful)

1. **Auth** (AppAuth + ASWebAuthenticationSession + Keychain). ([Apple Developer][12])
2. **Repositories + local DB** (SwiftData/GRDB); UI reads local-first. ([Apple Developer][7])
3. **List UI** with `Table` + search + sort. ([Apple Developer][2])
4. **Op-log mutations** with optimistic UI and ETag-aware writes. ([MDN Web Docs][16])
5. **WebSocket events** to keep list/detail fresh. ([Apple Developer][11])

---

## 13) Library Picks (quick reference)

* **GraphQL:** Apollo iOS (normalized + SQLite cache). ([Apollo GraphQL][5])
* **REST:** Swift OpenAPI Generator (typed clients). ([Swift.org][6])
* **DB:** SwiftData (simple) / GRDB (power). ([Apple Developer][7])
* **Realtime:** URLSessionWebSocketTask. ([Apple Developer][11])
* **Reachability:** Network framework `NWPathMonitor`. ([Apple Developer][9])
* **Images:** Nuke / Kingfisher. ([GitHub][13])
* **Auth:** AppAuth + ASWebAuthenticationSession. ([openid.github.io][17])
* **Crash/Perf:** Sentry Cocoa. ([Sentry Docs][15])
* **Logging:** swift-log + OSLog. ([GitHub][14])

---

### Appendix: Useful APIs

* `NavigationSplitView` (three-column) — Apple Docs. ([Apple Developer][1])
* `Table` (macOS list) — Apple Docs. ([Apple Developer][2])
* `.searchable` — Apple Docs. ([Apple Developer][3])
* `CommandMenu` & `keyboardShortcut` — Apple Docs. ([Apple Developer][4])
* `URLSessionWebSocketTask` — Apple Docs. ([Apple Developer][11])
* `NWPathMonitor` — Apple Docs. ([Apple Developer][9])
* ETag/If-None-Match/If-Match/412/304 — MDN. ([MDN Web Docs][18])
* Apollo iOS caching — Apollo Docs. ([Apollo GraphQL][5])
* Swift OpenAPI Generator — Apple Blog/GitHub. ([Swift.org][6])
* AppAuth & ASWebAuthenticationSession — OpenID & Apple Docs. ([openid.github.io][17])