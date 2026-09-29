# Initial headless sample — 2026-09-29

Recorded report: [2026-09-29-headless-1m.json](2026-09-29-headless-1m.json).

- Apple M5, model `Mac17,2`, 32 GiB system memory; arm64.
- macOS 26.5.1, build 25F80.
- Xcode 26.6, build 17F113; Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`).
- Release Swift package executable, bundled libpq 17.9; dependency versions and binary hashes are recorded in `Vendor/PostgreSQL/manifest.json`.
- Separate local PostgreSQL 17.9 Homebrew server on `127.0.0.1:55439`, database `postgres`; TLS disabled for the local fixture. Server memory is excluded.
- One million rows, eight columns, 16 MiB resident result budget, 512 MiB spool quota, no consumer delay.

The recorded sample streamed and spooled all rows in **1.735 seconds**. Its first batch reached the consumer in **28.1 ms** and was stored in **29.8 ms**. The kernel process-lifetime physical-footprint peak was **19.9 MiB**; resident-set peak was **26.1 MiB**. The page cache accounted for **15.8 MiB** at completion and the temporary spool contained **311.6 MiB**. All eight values in the first and last rows round-tripped exactly after page eviction, including NULL versus empty string, exact numeric text, and Unicode.

The separate `pg_sleep(30)` check delivered zero rows, acknowledged the cancellation request in **0.17 ms**, and recovered with SQLSTATE `57014` in **1.39 ms**; a subsequent query succeeded in the same session. These timings are local-server observations.

An additional 10,000-row smoke run with a 1 ms delay per consumed batch passed, including cancellation and endpoint verification. Its data fit in the resident cache, so it was not an eviction test.

This is an initial sample on an M5, not the plan's M1 reference machine and not an acceptance distribution. No app launch, UI scrolling, editor layout, input responsiveness, or main-thread commit budget has been measured here. No desktop control or UI automation was used. The memory numbers describe the headless executable rather than the full application.
