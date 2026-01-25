# Database Structure

## Overview
- Engine: SQLite (via SQLite.swift).
- File: `~/Library/Application Support/YouTrek/YouTrek.sqlite` (created on first use).
- Migrations: tables are created with `CREATE TABLE IF NOT EXISTS`; additive columns are applied with `ALTER TABLE ... ADD COLUMN` after a `PRAGMA table_info` check. There is no explicit schema version table.

## Tables

### `issues`
Primary key: `id`.

| Column | Type | Null | Notes |
| --- | --- | --- | --- |
| `id` | TEXT | no | UUID string. |
| `readable_id` | TEXT | no | Human-readable key. |
| `title` | TEXT | no | Issue title. |
| `project_name` | TEXT | no | Project display name. |
| `updated_at` | DOUBLE | no | Unix time (seconds). |
| `last_seen_updated_at` | DOUBLE | yes | Last seen server update time. |
| `assignee_id` | TEXT | yes | UUID string. |
| `assignee_name` | TEXT | yes | Display name. |
| `assignee_avatar_url` | TEXT | yes | URL string. |
| `assignee_login` | TEXT | yes | Login handle. |
| `assignee_remote_id` | TEXT | yes | Remote identifier. |
| `reporter_id` | TEXT | yes | UUID string. |
| `reporter_name` | TEXT | yes | Display name. |
| `reporter_avatar_url` | TEXT | yes | URL string. |
| `priority` | TEXT | no | Enum raw value. |
| `priority_rank` | INTEGER | no | Sort rank. |
| `status` | TEXT | no | Enum raw value. |
| `tags_json` | TEXT | no | JSON array of strings. |
| `custom_fields_json` | TEXT | yes | JSON object `[String: [String]]`. |
| `is_dirty` | INTEGER | no | Boolean (0/1). Default `0`. |
| `local_updated_at` | DOUBLE | yes | Unix time (seconds) for local edits. |

Notes:
- `is_dirty` marks locally edited issues awaiting sync.
- JSON fields are encoded via `JSONEncoder` and stored as UTF-8 strings.

### `issue_queries`
Primary key: composite (`query_key`, `issue_id`).

| Column | Type | Null | Notes |
| --- | --- | --- | --- |
| `query_key` | TEXT | no | Stable hash string for a query (filters/search/sort/page). |
| `issue_id` | TEXT | no | UUID string; joins to `issues.id`. |
| `last_seen_at` | DOUBLE | no | Unix time (seconds). |
| `sort_index` | INTEGER | no | Position in query results. |

Notes:
- Used as a cache index for lists of issues per query.
- No explicit foreign keys are declared.

### `issue_mutations`
Primary key: `id`.

| Column | Type | Null | Notes |
| --- | --- | --- | --- |
| `id` | TEXT | no | UUID string. |
| `issue_id` | TEXT | no | UUID string; related to `issues.id`. |
| `kind` | TEXT | no | Mutation type (currently `update`). |
| `payload_json` | TEXT | no | JSON-encoded `IssuePatch`. |
| `local_changes` | TEXT | no | Human-readable summary. |
| `created_at` | DOUBLE | no | Unix time (seconds). |
| `last_attempt_at` | DOUBLE | yes | Unix time (seconds). |
| `retry_count` | INTEGER | no | Default `0`. |
| `last_error` | TEXT | yes | Error description. |

Notes:
- Acts as an outbox for offline changes.

### `issue_boards`
Primary key: `id`.

| Column | Type | Null | Notes |
| --- | --- | --- | --- |
| `id` | TEXT | no | Board identifier. |
| `name` | TEXT | no | Board name. |
| `is_favorite` | INTEGER | no | Boolean (0/1). Default `0`. |
| `project_names_json` | TEXT | no | JSON array of strings. |
| `sprints_json` | TEXT | yes | JSON array of sprint objects. |
| `current_sprint_id` | TEXT | yes | Current sprint identifier. |
| `sprint_field_name` | TEXT | yes | Field name used for sprints. |
| `column_field_name` | TEXT | yes | Field name for columns. |
| `columns_json` | TEXT | yes | JSON array of column objects. |
| `swimlane_json` | TEXT | yes | JSON swimlane settings. |
| `orphans_at_top` | INTEGER | yes | Boolean (0/1). |
| `hide_orphans_swimlane` | INTEGER | yes | Boolean (0/1). |
| `updated_at` | DOUBLE | yes | Unix time (seconds). |

Notes:
- Board configuration data is cached as JSON blobs.
