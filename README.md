# PGDesk

A small native macOS app (SwiftUI + [PostgresNIO](https://github.com/vapor/postgres-nio)) for browsing and querying PostgreSQL.

- **Connections**: saved in UserDefaults, passwords in the Keychain. SSL: disable / prefer / require (no certificate verification, like libpq's `require`).
- **Sidebar**: databases → schemas → tables, views, materialized views. Each database you expand opens its own connection.
- **Table viewer**: paged rows (100/500/1000), click a header to sort on the server, Structure tab with types, nullability, defaults and primary key. ⌘[ / ⌘] change page, ⌘R refreshes.
- **SQL editor**: one per database. ⌘↩ runs the whole text, or only the selection. Results are capped at 10,000 rows. ⌘C copies selected rows as tab-separated text.

## Build and run

```sh
scripts/bundle.sh --open   # release build → build/PGDesk.app
swift run PGDesk           # quick debug run without a bundle
swift test                 # core tests; need a local Postgres (current user, no password)
```

Open `Package.swift` in Xcode to edit and debug.

## Layout

- `Sources/PGDeskCore`: connection, cell decoding, catalog queries, paging (no UI)
- `Sources/PGDesk`: the SwiftUI app
- `Tests/PGDeskCoreTests`: runs against local Postgres using temp tables only

## Known limits

- One statement per run. PostgresNIO uses the extended protocol, so `select 1; select 2` is rejected by the server.
- PostgresNIO always asks for binary results. Common types are decoded directly. Table pages cast every column to text. If an editor query hits a type with no binary output (e.g. `aclitem`), it's re-run as text, which only works for SELECT/VALUES/TABLE queries.
- No cell editing, syntax highlighting, autocomplete or query cancel yet.
