# Catalog fixture measurements — 2026-09-29

This record covers the direct PostgreSQL catalog backend from [task 05](../Plans/05-objects.md). It is one local debug-test sample; it does not establish server performance budgets or measure the native sidebar.

## Environment and reproduction

- Apple silicon, model `Mac17,2`, arm64.
- macOS 26.5.1, build 25F80.
- Xcode 26.6, build 17F113; Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`).
- Swift package tests built in Debug configuration, using the bundled libpq 17.9 driver.
- Disposable local PostgreSQL 17.9 Homebrew server, UTF-8, `--no-locale`, fresh temporary data directory, loopback address and dynamically selected port. The measured catalog used the local trust-authentication fixture with TLS disabled. Separate TLS and SCRAM servers exercise connection handling in the same integration command.
- No saved db3 profile, project `.env`, or production database was used. The fixture schemas, roles, servers, and data directories are removed by test cleanup.

From the repository root:

```sh
./Scripts/test.sh --integration
```

The measurement source is [`CatalogPostgresTests.testLargeDisposableCatalogPublishesBoundedPagesAndReportsSearchTiming`](../Packages/DB3Kit/Tests/DB3CoreTests/CatalogTests.swift). It creates 5,500 views in a uniquely named schema, each with a constant one-column result. It loads the first catalog page, searches for the final view by schema-qualified name, then removes views in batches of 250 to keep fixture teardown within PostgreSQL's default lock budget.

The recorded output came from the package portion of `/tmp/db3-objects-full-integration-final.log`. That temporary log is a local execution artifact; the test source and measurements below are the durable record. This run passed 78 XCTest cases plus 13 Swift Testing cases in the package, including 10 catalog integration tests and two catalog type tests. These counts and measurements cover the package/backend; complete workbench-suite and app-build verification are tracked separately in task 05.

## Recorded sample

| Observation | Result |
| --- | ---: |
| Eligible relations in the fixture schema | 5,500 views |
| Published objects in the first page | 500 |
| First-page elapsed time | 11.898 ms |
| Targeted server search elapsed time | 2.426 ms |
| Objects returned by targeted search | 1 |
| First-page decoded object accounting | 299,000 bytes, about 292 KiB |

The first-page timer starts before calling a fresh `PostgresCatalogService`, so it includes connection setup, session timeout configuration, database-identity verification, the catalog query, and decoding. The targeted search reuses that authenticated catalog session. Both timings exclude fixture creation and deletion. The query fetches at most 501 rows to publish 500 objects and determine whether another page exists; it does not fetch all 5,500 names and filter them locally.

The byte figure sums `DatabaseObject.byteCount`, a conservative decoded-value accounting estimate used by the cache. It is not measured resident memory, peak process footprint, total application memory, or PostgreSQL server memory. The in-memory browser limits remain 5,000 cached objects and 8 MiB app-wide; this sample alone does not prove those limits.

## Separate correctness coverage

The [catalog integration tests](../Packages/DB3Kit/Tests/DB3CoreTests/CatalogTests.swift) verify supported relation kinds, partitions, materialized-view population state, schema/name quoting, duplicate names, cross-schema visibility, table/column/schema privilege annotations and revocation, literal server search beyond page one, bound values and SQL NULL, single-statement enforcement, rename/drop/recreate, and identity invalidation on reconnect or source revision.

A locked `pg_class` fixture verifies operation-specific cancellation and the 10-second statement deadline, followed by a successful query on the recovered session. Concurrent requests with 16 source revisions are monitored through `pg_stat_activity` and remain within one catalog session. Separate SCRAM startup checks distinguish missing/incorrect passwords from a missing database and a TLS configuration failure.

A final live isolation test verifies that catalog reads leave a worksheet's open/failed transaction and running `pg_sleep` unchanged, hide its temporary/uncommitted relations, and discover newly committed DDL. The complete final integration run passed 95 package XCTest cases, 13 Swift Testing cases, and 80 workbench XCTest cases; the catalog portion contains 11 real integration tests and two type tests. The Release app build and bundle verification also passed. These later validation counts are separate from the timing sample recorded above.

The [browser model tests](../Tests/DB3WorkbenchTests/ObjectBrowserModelTests.swift) use a separate synthetic 50,000-object service to verify 500-row publications, the 5,000-row cap, and search beyond that cap. Additional model cases verify byte limits, eviction, stale responses, credential generations, and cancellation. These deterministic service fixtures are correctness tests rather than PostgreSQL timing measurements.

## Remaining measurements

No app launch timing, native list scrolling, input latency, VoiceOver operation, sidebar resizing, UI memory, or main-thread publication budget was measured here. Interactive checks remain pending. The sample has no repeated-run distribution and does not cover remote latency, large numbers of schemas, concurrent DDL load, other server versions, or production permission complexity. Only PostgreSQL 17.9 was exercised by these disposable fixtures.
