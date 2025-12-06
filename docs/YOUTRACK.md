# YouTrack_API.md

A concise, engineer-friendly guide to YouTrack’s REST API for building a lightweight desktop client that can:

* fetch issues by project and filters,
* create and update issues,
* read agile boards & sprints,
* read Knowledge Base (articles),
* authenticate users (OAuth via JetBrains Hub) or use Personal Access Tokens.

> **API style:** modern REST with *field projections* (the `fields` param), server-side filtering via the YouTrack query language (the `query` param), and pagination via `$top`/`$skip`.

---

## 0) Base URL & Versions

* **Cloud & Server:** the REST API lives under `/<service>/api`.

  * Cloud examples: `https://acme.youtrack.cloud/api` or legacy `https://acme.myjetbrains.com/youtrack/api`.
  * Server examples: `https://youtrack.example.com/api` or `https://www.example.com/youtrack/api`.
* YouTrack’s REST API is versioned by product releases; you target the *current* API that your instance exposes. Treat entity shapes as stable per release, but **always** request only what you need via `fields` (see below).

---

## 1) Authentication Options

### OAuth 2.0 via JetBrains **Hub** 

* Register an OAuth client in **Hub** (bundled with YouTrack Cloud/Server):

  * Grant type: **Authorization Code + PKCE** (native-app standard).
  * Redirect URI: **loopback** (e.g., `http://127.0.0.1:48000/callback`) or a **custom URI scheme** (`yourapp://oauth2redirect`). Use system browser.
  * Scopes: request **YouTrack** (add others only if needed).
  
  > **macOS client setup:** before launching YouTrek, export the following so the AppAuth integration can negotiate with Hub:
  > 
  > * `YOUTRACK_BASE_URL` – REST base (for example `https://acme.youtrack.cloud/api`).
  > * `YOUTRACK_HUB_AUTHORIZE_URL` – Hub authorize endpoint (`https://<hub>/api/rest/oauth2/auth`).
  > * `YOUTRACK_HUB_TOKEN_URL` – Hub token endpoint (`https://<hub>/api/rest/oauth2/token`).
  > * `YOUTRACK_CLIENT_ID` – the OAuth client identifier from Hub.
  > * `YOUTRACK_REDIRECT_URI` – the redirect URI you registered (loopback or custom scheme).
  > * (Optional) `YOUTRACK_SCOPES` – comma separated overrides; defaults to `YouTrack`.
* Endpoints (your actual Hub base depends on your deployment):

  * **Authorize:** `<HUB_BASE>/api/rest/oauth2/auth`
  * **Token:** `<HUB_BASE>/api/rest/oauth2/token`
* Store the resulting **access token** (short-lived) and, if issued, **refresh token**. Inject `Authorization: Bearer <access_token>` on each REST call.
* The macOS client now negotiates tokens via AppAuth + ASWebAuthenticationSession and stores the refresh token securely in Keychain. No PAT or token environment variables are required at runtime.
* UX tip: offer both **“Sign in with YouTrack (Browser)”** *and* **“Use Personal Token”** as fallback.

> **Native-app hygiene:** use PKCE, open the system browser, and listen on a localhost/loopback port for the redirect. Avoid embedded webviews.

---

## 2) Core Patterns You’ll Use Everywhere

### 2.1 Field Projections (`fields`)

You **must** ask for attributes explicitly; otherwise the server returns only an entity stub (ID/type). The projection language is nested and composable:

```txt
fields=id,idReadable,summary,project(shortName,name),
       reporter(login,name),updated,customFields(name,value(name))
```

### 2.2 Server-side Filtering (`query`)

Use YouTrack’s search syntax (same as in the UI) via `query=...`. Examples:

```txt
project: ACME #Unresolved assignee: me sort by: updated desc
created: 2025-09-01 .. 2025-10-14
updated: 2025-10-01 .. *  # “delta since” sync pattern
```

### 2.3 Pagination (`$top`, `$skip`)

Most collection endpoints return **42 items by default**. Page with `$top` and `$skip`. Your client should consistently page, rather than trying to fetch “everything”.

---

## 3) Projects & Issues

### 3.1 List projects

```bash
curl -s "$BASE/api/admin/projects?fields=id,name,shortName&\$top=100" \
  -H "Authorization: Bearer $TOKEN"
```

### 3.2 Fetch issues by project + filter

Prefer **one** `/api/issues` call with a `query` that names the project:

```bash
curl -s "$BASE/api/issues?query=$(python - <<'PY'\nimport urllib.parse\nprint(urllib.parse.quote('project: ACME #Unresolved for: me sort by: updated desc'))\nPY)\
&fields=id,idReadable,summary,project(shortName),reporter(login),updated,\
customFields(name,value(name))&\$top=100&\$skip=0" \
  -H "Authorization: Bearer $TOKEN"
```

> Tip: build a small helper that percent-encodes the query and appends standard `fields` + pagination automatically.

### 3.3 Create a new issue

Required: `summary`, `project.id` (DB ID, not the short name). You can discover a project’s DB ID from step **3.1**.

```bash
curl -s -X POST "$BASE/api/issues?fields=idReadable" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "summary": "Desktop client: cannot sign in when offline",
        "description": "Repro: ...",
        "project": { "id": "0-0" },
        "customFields": [
          { "$type": "SingleEnumIssueCustomField", "name": "Type", "value": { "name": "Bug" } },
          { "$type": "SingleEnumIssueCustomField", "name": "Priority", "value": { "name": "Critical" } }
        ]
      }'
```

Permissions required: **Create Issue** in the target project.

### 3.4 Update an issue (partial update)

```bash
curl -s -X POST "$BASE/api/issues/2-42?fields=idReadable,summary" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{ "summary": "New summary from API" }'
```

### 3.5 Apply **commands** (fast, multi-field changes; add comments; move sprint, etc.)

```bash
curl -s -X POST "$BASE/api/commands?fields=issues(id,idReadable)" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
        "query": "ACME-123",
        "commands": "State Fixed Priority Major Assignee me",
        "comment": { "text": "Handled via API" }
      }'
```

### 3.6 Attach a file

```bash
curl -s -X POST "$BASE/api/issues/ACME-123/attachments?fields=id,name" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@./screenshot.png"
```

---

## 4) Custom Fields & Allowed Values (for UI dropdowns)

You’ll often need the **allowed values** to populate pickers (Priority/Type/State, Versions, Assignee, etc.).

* For a project’s custom fields list:

  ```bash
  curl -s "$BASE/api/admin/projects/<projectId>/customFields?\
  ```

fields=id,field(name,fieldType(id,kind)),bundle(id,name)" 
-H "Authorization: Bearer $TOKEN"

````
- Get values for an **enum** bundle:
```bash
curl -s "$BASE/api/admin/customFieldSettings/bundles/enum/<bundleId>?fields=id,name,values(id,name)" \
  -H "Authorization: Bearer $TOKEN"
````

* Many field kinds (`state`, `version`, `ownedField`, `user`) have their own bundle endpoints; the pattern is the same (`.../bundles/<kind>`).

> Your client should cache these bundle values per project and refresh occasionally (or on 404/validation errors while posting an issue).

---

## 5) Saved Searches (filters) → issues

Let users pick a saved search and you fetch its result set:

```bash
# list saved searches visible to the current user
curl -s "$BASE/api/savedQueries?fields=id,name,query&\$top=100" \
  -H "Authorization: Bearer $TOKEN"

# fetch issues for a specific saved search (via the 'issues' relation in fields)
curl -s "$BASE/api/savedQueries/<id>?fields=name,issues(\
id,idReadable,summary,project(shortName),updated)" \
  -H "Authorization: Bearer $TOKEN"
```

Alternatively, just reuse the saved search’s `query` with `/api/issues` to control pagination yourself.

---

## 6) Agile Boards & Sprints

### 6.1 List agile boards

```bash
curl -s "$BASE/api/agiles?fields=id,name,projects(shortName,name)" \
  -H "Authorization: Bearer $TOKEN"
```

### 6.2 List sprints on a board

```bash
curl -s "$BASE/api/agiles/<agileId>/sprints?fields=id,name,start,finish,archived" \
  -H "Authorization: Bearer $TOKEN"
```

### 6.3 Get issues in a sprint

The `Sprint` entity exposes an `issues` collection. Request it explicitly in `fields`:

```bash
curl -s "$BASE/api/agiles/<agileId>/sprints/<sprintId>\
?fields=id,name,start,finish,issues(id,idReadable,summary,customFields(name,value(name)))" \
  -H "Authorization: Bearer $TOKEN"
```

(For large sprints, prefer `/api/issues?query=Board: <boardName> Sprint: <sprintName>` and paginate.)

---

## 7) Knowledge Base (Articles)

### 7.1 List articles (flat or hierarchical fetch via `parentArticle/childArticles`)

```bash
curl -s "$BASE/api/articles?fields=id,idReadable,summary,updated,\
author(login),parentArticle(idReadable),childArticles(idReadable)" \
  -H "Authorization: Bearer $TOKEN"
```

### 7.2 Read one article (with content)

```bash
curl -s "$BASE/api/articles/<articleId>?fields=idReadable,summary,content,updated,attachments(name,id)" \
  -H "Authorization: Bearer $TOKEN"
```

### 7.3 Search articles

Use the same `query` semantics as issues where supported (title/text match is typical). If your instance is large, combine a minimal `fields` with paging.

---

## 8) Query Assist (typeahead) — great for your “filter” UI

Post the in-progress query and get completions/suggestions (mirrors the web UI’s assist):

```bash
curl -s -X POST "$BASE/api/search/assist?fields=query,\
suggestions(option,description,completionStart,completionEnd)" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{ "query": "project: ACME #Unres", "caret": 18 }'
```

---

## 9) Delta Sync Strategy (for offline-first)

For periodic sync, ask only for entities changed since your last checkpoint:

```bash
# 1) remember lastSync (UTC) in ISO (e.g., 2025-10-13T21:00)
# 2) query only the delta by updated timestamp
curl -s "$BASE/api/issues?query=$(python - <<'PY'\nimport urllib.parse\nprint(urllib.parse.quote('project: ACME updated: 2025-10-13T21:00 .. *'))\nPY)\
&fields=id,idReadable,summary,updated,customFields(name,value(name))&\$top=100&\$skip=0" \
  -H "Authorization: Bearer $TOKEN"
```

Prefer multiple small pages; store a per-project high-watermark (`lastSeenUpdated`) to resume on restart.

---

## 10) Error Handling & Pitfalls

* **Always project fields.** If you omit `fields`, you’ll get skinny objects (IDs/types) and your client will look “empty”.
* **Respect pagination.** Default max for many collections is **42**. Use `$top`/`$skip` consistently.
* **IDs vs idReadable:** API often uses DB IDs (`"0-0"`) while users see `ACME-123`. You can use `idReadable` for many endpoints that accept it, but prefer DB IDs for updates.
* **Custom fields are typed.** When posting `customFields`, the `$type` must match the field kind (e.g., `SingleEnumIssueCustomField`). If a field is **conditional** (hidden by rules), updating it may error until the condition is satisfied.
* **Permissions matter.** “Create Issue”, “Update Issue”, “Read Article”, etc., are enforced per project/space. Bubble these failures up with actionable messages.
* **Legacy REST (`/rest/...`)** exists but is deprecated—stick to `/api/...` only.

---

## 11) UX & Security Recommendations for a Desktop Client

* **Offer two auth paths:** “Sign in (Browser, OAuth + PKCE)” and “Paste Token”. Detect auth failures and fall back elegantly.
* **Store tokens securely:** macOS Keychain / Windows DPAPI / Linux Secret Service. Never log tokens. Provide **Sign out** (revoke token if you manage it) and **Switch account**.
* **Make `fields` a first-class preset.** Ship with sensible projections (issue list, issue details, sprint list) and allow power users to edit field sets.
* **Cache bundles (field options)** per project; refresh when you see 400s on create/update.
* **Batch small writes** with **Commands** when appropriate (state + priority + comment in one round-trip).
* **Robust network layer:** timeouts, retries with backoff for 429/5xx, and safe cancellation.

---

## 12) Quick Endpoint Index

* **Projects:** `/api/admin/projects`
* **Issues:** `/api/issues` (+ sub-resources: `/comments`, `/attachments`, `/links`, `/activities`, `/customFields`, `/sprints`)
* **Commands:** `/api/commands`
* **Saved searches:** `/api/savedQueries`
* **Agile:** `/api/agiles`, `/api/agiles/{id}/sprints`
* **Articles (KB):** `/api/articles`
* **Users (profile data in YouTrack):** `/api/users` *(authorization/user management lives in Hub)*
* **Custom field bundles:** `/api/admin/customFieldSettings/bundles/{enum|state|version|ownedField|user}`

---

## 13) Minimal Client Skeleton (pseudo-code)

```pseudo
class YTClient {
  constructor(baseUrl, auth)  // auth = token | (oauthCfg + tokenStore)
  request(path, {method, params, headers, body})
  issues.list({query, fields, top, skip})
  issues.create({projectId, summary, description, customFields})
  issues.update(id, patch)
  issues.attach(id, filePath)
  commands.apply({issuesQueryOrIds, command, comment})
  agiles.list(fields)
  agiles.sprints(agileId, fields, top, skip)
  savedQueries.list(fields)
  articles.list(fields, top, skip)
  articles.get(id, fields)
  bundles.enumValues(bundleId)
}
```

---

## 14) Troubleshooting Cheats

* Getting “empty” objects? → you forgot `fields=...`.
* Not filtering? → use `/api/issues?query=...` (not `/api/admin/projects/{id}/issues` for queries).
* 403/404 on create/update? → permissions or wrong project **DB ID**; also check conditional fields.
* Seeing only part of a list? → add `&$top=<n>&$skip=<m>` and page.
* Need sprint issues? → request `.../agiles/{id}/sprints/{id}?fields=issues(...)` or filter via `/api/issues` with Board/Sprint in the query.

---

## 15) Environment Variables For cURL Examples

```bash
# base url of your instance (ending with /api)
export BASE="https://acme.youtrack.cloud/api"
# PAT token (or an OAuth access token)
export TOKEN="perm:XXXX"
```

---

### Appendix: Handy `fields` presets

* **Issue list:**

  ```txt
  id,idReadable,summary,project(shortName),reporter(login,name),updated,\
  customFields(name,value(name)),tags(name)
  ```
* **Issue details:**

  ```txt
  id,idReadable,summary,description,wikifiedDescription,reporter(login,name),\
  created,updated,comments(text,author(login),created),attachments(name,id),\
  customFields(name,value(name))
  ```
* **Sprint card:**

  ```txt
  id,name,start,finish,archived,agile(id,name),issues(id,idReadable,summary)
  ```