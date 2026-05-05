---
name: metabase
description: Query and manage the smalt Metabase instance (https://metabase.smalt.eu) via its REST API. Use when creating, updating, or organizing dashboards, cards (questions), collections, parameters, and click-behaviors. Read-only inspection is also possible directly against the Metabase internal Postgres via the `database` skill.
---

# Metabase

Manage the smalt Metabase instance via the REST API.

This skill exposes one MCP tool — `mcp__metabase__query` — that proxies HTTP
requests to Metabase. Treat it as a thin wrapper around `curl`: pick the
HTTP method, the endpoint path (relative to `/api`), and an optional JSON
body. The full response body is returned as a string.

## ⚠️ Safety Rules

- **Production-only instance.** Every change you make is visible to all users immediately. Confirm with the user before:
  - Creating dashboards or cards in shared collections.
  - Editing or deleting existing cards/dashboards (`PUT`/`DELETE`).
  - Moving items between collections.
  - Touching collection permissions (`/collection/graph`).
- Prefer `archived: true` over `DELETE` for cards/dashboards/collections — it's reversible.
- When making non-trivial changes, fetch the existing object first (`GET /card/:id`), modify the JSON, then `PUT` it back. Avoid blindly overwriting fields.
- For exploratory reads of dashboards/cards/visualization_settings, the `database` skill (Metabase internal DB on port 5435, read-only) is faster than the REST API.

## Setup

The MCP server reads credentials from `~/.config/smalt/metabase.env` (a
two-line key=value file with `METABASE_BASE_URL` and `METABASE_API_KEY`).
See the plugin README for one-off setup. Process env vars of the same
names also work and take precedence — handy for overriding the base URL
in a different environment.

Quick auth sanity check:

```
mcp__metabase__query(method="GET", endpoint="/user/current")
```

The API key is bound to a single Metabase user; group permissions of that
user apply. For most chart/dashboard work a non-superuser API key is fine,
but a few endpoints (public-link toggle, site settings, user/permissions
admin) require superuser scope.

## Calling the tool

```
mcp__metabase__query(method, endpoint, body?)
```

- `method`: `GET` | `POST` | `PUT` | `DELETE` | `PATCH`
- `endpoint`: path relative to `/api` (e.g. `/card/153`)
- `body` (optional): a JSON-serializable object, or a pre-formatted string

Examples:

```
# Whoami / sanity check
mcp__metabase__query(method="GET", endpoint="/user/current")

# List collections
mcp__metabase__query(method="GET", endpoint="/collection")

# Items inside a collection
mcp__metabase__query(method="GET", endpoint="/collection/12/items")

# Get a single card (question)
mcp__metabase__query(method="GET", endpoint="/card/153")

# Get a dashboard with all dashcards & parameters
mcp__metabase__query(method="GET", endpoint="/dashboard/12")

# Create a card
mcp__metabase__query(method="POST", endpoint="/card", body={...})

# Patch a card name
mcp__metabase__query(method="PUT", endpoint="/card/153", body={"name": "renamed"})

# Archive a card (preferred over DELETE)
mcp__metabase__query(method="PUT", endpoint="/card/153", body={"archived": true})
```

The response is the raw Metabase response body as a string — usually JSON,
which you can parse before reasoning over it.

## Common Endpoints

| Purpose | Endpoint |
|---------|----------|
| Current user / token check | `GET /user/current` |
| List databases (with `id`s used in `dataset_query.database`) | `GET /database` |
| **Run arbitrary SQL on any connected DB** | `POST /dataset` (see below) |
| List collections | `GET /collection` |
| Items in a collection | `GET /collection/:id/items` |
| Create / update / archive collection | `POST /collection`, `PUT /collection/:id` |
| Collection permissions matrix | `GET /collection/graph`, `PUT /collection/graph` |
| Get / update / archive a card | `GET /card/:id`, `PUT /card/:id` (`archived: true`) |
| Create card | `POST /card` |
| Run a card and return rows | `POST /card/:id/query` |
| Get dashboard (incl. dashcards, parameters, tabs) | `GET /dashboard/:id` |
| Create dashboard | `POST /dashboard` |
| Update dashboard (incl. dashcards array) | `PUT /dashboard/:id` |

For the canonical reference see https://www.metabase.com/docs/latest/api-documentation.

## Schema introspection

Two equally-good paths for understanding table shapes:

```
# (A) Raw SQL on information_schema (any connected DB)
mcp__metabase__query(method="POST", endpoint="/dataset", body={
  "database": 2,
  "type": "native",
  "native": {
    "query": "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='invoices' ORDER BY ordinal_position"
  }
})

# (B) Metabase's catalog (richer: FKs, semantic types, display names)
mcp__metabase__query(method="GET", endpoint="/database/2/metadata")
mcp__metabase__query(method="GET", endpoint="/table/:table_id/query_metadata")
```

(B) is more compact when you want a single field's metadata or want to follow FKs;
(A) is the right choice for exploratory `\d`-style work.

## Ad-hoc SQL via `POST /dataset`

Runs native SQL against any database Metabase connects to and returns
rows as JSON — no card needs to exist. Use this for ad-hoc data lookups
and cross-checks against chart values.

```
# Smalt-Prod (database 2)
mcp__metabase__query(method="POST", endpoint="/dataset", body={
  "database": 2,
  "type": "native",
  "native": {"query": "SELECT count(*) FROM projects WHERE deleted_at IS NULL"}
})

# Attio Data (database 5)
mcp__metabase__query(method="POST", endpoint="/dataset", body={
  "database": 5,
  "type": "native",
  "native": {"query": "SELECT count(*) FROM invoices WHERE date_invoiced >= '2026-04-01'"}
})
```

The response shape is:

```json
{
  "data": {
    "cols": [{"name": "...", "base_type": "type/Integer"}, ...],
    "rows": [[...], [...], ...],
    "rows_truncated": 2000
  },
  "row_count": 2000
}
```

Metabase truncates large result sets (default ~2000 rows). For bigger
exports, paginate via `LIMIT/OFFSET` in the SQL or set
`"middleware": {"add-default-userland-constraints?": false}` on the
request body.

Database IDs in this workspace (run `GET /database` to confirm):

| ID | Name | Engine |
|----|------|--------|
| 2 | Smalt-Prod | postgres (read-only via Metabase user) |
| 5 | Attio Data | postgres (read-only) |
| 3 | prod-scraper | mongo |
| 1 | Sample Database | h2 |

**The DB connection user is read-only**, so `INSERT`/`UPDATE`/`DELETE`
statements via `/dataset` will fail. To modify Metabase content (cards,
dashboards, collections, permissions) use the dedicated REST endpoints.

## Card (Question) Anatomy

A SQL/native card body looks roughly like:

```json
{
  "name": "Projektliste",
  "description": null,
  "collection_id": null,
  "display": "table",
  "visualization_settings": {},
  "dataset_query": {
    "type": "native",
    "database": 2,
    "native": {
      "query": "SELECT ...",
      "template-tags": {
        "partner_name": {
          "id": "uuid-here",
          "name": "partner_name",
          "display-name": "Partner Name",
          "type": "text",
          "required": false
        }
      }
    }
  },
  "parameters": [
    {"id":"uuid","slug":"partner_name","name":"Partner Name","type":"category","target":["variable",["template-tag","partner_name"]]}
  ]
}
```

- `database` is the Metabase database ID. Common ones in this workspace:
  - `2` — smalt prod (`smalt-prod` Cloud SQL)
  - `5` — Attio data (`attio_data`)
  - Run `GET /database` to confirm.
- For parameters you want exposed to dashboard filters / URL params, both
  `template-tags` (inside `native`) **and** the top-level `parameters` array
  must reference the same UUID.

## Dashboard Anatomy

A dashboard's `dashcards` array carries one entry per visualisation, with
position (`row`, `col`, `size_x`, `size_y`), the underlying `card_id`, and a
`visualization_settings` blob that holds chart-level overrides and the
`click_behavior`.

Click-behavior to a saved question via URL (used to pass column values into
drill-down questions) looks like:

```json
"visualization_settings": {
  "click_behavior": {
    "type": "link",
    "linkType": "url",
    "linkTemplate": "/question/153?partner_name={{partner_name}}&created_week={{week}}"
  }
}
```

`{{column_name}}` placeholders pull values from the clicked row;
`{{filter_name}}` pulls values from dashboard filters with that slug.

## Tips

- When creating cards/dashboards via `POST`, `collection_id: null` puts them
  in the user's personal collection. Pass an explicit `collection_id` (or
  move them via `PUT /card/:id`) once happy.
- When editing existing cards, fetch the current JSON, mutate, and `PUT` it
  back. The API expects the full object on `PUT`, not a patch.
- For complex bodies, build the dict in code and pass it as the `body`
  argument — much easier than escaping JSON inline.
- Cross-check anything you build by hitting the same endpoints with `GET`
  before and after a `PUT`/`POST` to confirm the expected diff.
