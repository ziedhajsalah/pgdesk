# PGDesk

A small native macOS app (SwiftUI + [PostgresNIO](https://github.com/vapor/postgres-nio)) for browsing and querying PostgreSQL.

- **Connections**: saved in UserDefaults, passwords in the Keychain. SSL: disable / prefer / require (no certificate verification, like libpq's `require`).
- **Sidebar**: databases → schemas → tables, views, materialized views. Each database you expand opens its own connection.
- **Table viewer**: paged rows (100/500/1000), click a header to sort on the server, Structure tab with types, nullability, defaults and primary key. ⌘[ / ⌘] change page, ⌘R refreshes.
- **Cell editing**: in tables with a primary key, double-click a cell to edit it. Return saves, Esc cancels, ⌥Return adds a newline (the row grows for multi-line values). Right-click a cell for **Set to NULL**; an emptied cell saves `''`, not NULL. Each save runs `UPDATE … SET col = $1 WHERE pk = $2 … RETURNING …` with bound parameters and shows the row as stored. Errors show in a banner above the grid and the cell keeps its old value. Views, materialized views, foreign tables, tables without a primary key and system schemas stay read-only (the pager shows why).
- **SQL editor**: one per database. ⌘↩ runs the whole text, or only the selection. ⌘. (or the Stop button) cancels a running query. Keywords, strings (including `E''` and `$$` dollar quotes), numbers and comments are coloured. Results are capped at 10,000 rows. ⌘C copies selected rows as tab-separated text.
- **CSV export**: the toolbar's share button saves the current result (query editor) or the current page (table viewer) as CSV, in the same format as `COPY … (format csv, header)`: NULL is an empty field, an empty string is `""`.

## Build and run

```sh
scripts/bundle.sh --open   # release build → build/PGDesk.app
swift run PGDesk           # quick debug run without a bundle
swift test                 # core tests; need a local Postgres (current user, no password)
```

Open `Package.swift` in Xcode to edit and debug.

## Layout

- `Sources/PGDeskCore`: connection, cell decoding, catalog queries, paging, row updates, query cancel, SQL lexer, CSV (no UI)
- `Sources/PGDesk`: the SwiftUI app
- `Tests/PGDeskCoreTests`: runs against local Postgres using temp tables only

## Known limits

- One statement per run. PostgresNIO uses the extended protocol, so `select 1; select 2` is rejected by the server.
- PostgresNIO always asks for binary results. Common types are decoded directly. Table pages cast every column to text. If an editor query hits a type with no binary output (e.g. `aclitem`), it's re-run as text, which only works for SELECT/VALUES/TABLE queries.
- Cell values are edited as text: the page casts every column to text and the update sends untyped parameters, so the server parses them with each column's input function. Values round-trip exactly on the same connection (timestamps use the session time zone).
- Cancel uses `pg_cancel_backend` from a short-lived second connection, because PostgresNIO has no public CancelRequest (cancelling a Swift task only stops reading rows; the server keeps running). Table pages and the editor share one connection per database, so a cancel stops whatever that connection is running.
- Syntax colouring re-lexes the whole text on each edit and recolours only the range whose tokens changed. On a 1 MB script, normal typing costs about 3 ms per key. The worst case is a keystroke that changes everything after it (an unclosed `'` or `/*` at the top), at about 10–40 ms.
- CSV export saves only the rows already loaded (one page, or at most 10,000 query rows).
- No autocomplete, and no inserting or deleting rows yet.
