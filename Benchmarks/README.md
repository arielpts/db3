# db3 headless performance harness

`db3-bench` measures the real asynchronous PostgreSQL driver feeding the bounded result store. Its default workload returns one million rows across eight scalar/text columns, approximately 256 payload bytes per row, into a 16 MiB resident page cache and a 512 MiB temporary spool quota. It validates every value in the first and last rows after streaming and checks cancellation of `pg_sleep(30)` before the first row, followed by successful execution in the same session.

The harness requires a disposable local PostgreSQL server. It runs only SELECT statements, uses TLS disabled for the local fixture, and deletes its temporary result store on success or failure. It does not create database objects.

From the repository root, after preparing the bundled native dependency:

```sh
DB3_TEST_PORT=55439 DB3_TEST_USER=ariel DB3_TEST_DATABASE=postgres \
  swift run --package-path Packages/DB3Kit -c release db3-bench \
  > Benchmarks/latest-headless.json
```

The default endpoint is `127.0.0.1:55439`, user `ariel`, database `postgres`. Override `DB3_TEST_HOST`, `DB3_TEST_PORT`, `DB3_TEST_USER`, `DB3_TEST_DATABASE`, and `DB3_TEST_PASSWORD` as needed. Passwords and row values are not printed in the report.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `DB3_BENCH_ROWS` | 1,000,000 | Stream size; 1–10,000,000 |
| `DB3_BENCH_RESIDENT_MIB` | 16 | Resident result-page accounting limit |
| `DB3_BENCH_SPOOL_MIB` | 512 | Temporary spool quota; increase for larger runs |
| `DB3_BENCH_CONSUMER_DELAY_MS` | 0 | Delay before each awaited append to exercise backpressure |
| `DB3_BENCH_CANCEL` | 1 | Set `0` to omit the cancellation/recovery check |

For a short smoke test, set `DB3_BENCH_ROWS=10000`. Small runs may not evict the first page; the JSON's `endpointInspectionExercisedEviction` reports whether the workload exceeded the resident cache. Failures produce a nonzero exit code and an error on stderr rather than a success report.

The JSON reports connection time; first received and first stored batch latency; complete driver-plus-spool duration; throughput; observed batch sizes; resident page accounting; spool bytes; exact endpoint verification; and cancellation acknowledgement/recovery durations. The batch-byte field uses `RowBatch.byteCount`, which includes a small container allowance. First-batch measurements include PostgreSQL execution and local transport. A configured consumer delay is included in the streaming duration.

Memory snapshots use Darwin `task_info(TASK_VM_INFO)` for physical footprint and current resident set, and `getrusage(RUSAGE_SELF)` for the kernel's resident-set high-water mark. The physical footprint peak is also a kernel process-lifetime peak. These are bytes and are distinct metrics; resident-page accounting is not process memory. The harness excludes the separate server process. Cleanup snapshots need not return immediately to startup memory because allocators can retain freed pages.

Record the Xcode/Swift version, bundled libpq version, exact hardware/OS, build configuration, and server configuration alongside each report. Use repeated Release runs to compare distributions and scaling; a single sample cannot establish an acceptance budget. The report records hardware model, OS, build configuration, and PostgreSQL server version itself.

## UI fixtures and remaining measurements

- `fixtures/narrow-million.sql` is the same eight-column workload for manual grid checks.
- `fixtures/wide-200.psql` generates a single 200-column SELECT for horizontal-scrolling checks; run it through `psql -X -At` and use its output as the worksheet SQL.
- `python3 Benchmarks/fixtures/make-editor-fixtures.py` creates a 1 MiB script and a separate 1 MiB single-line string literal. Generated SQL files may be removed after use.

This harness does **not** measure app launch, idle app footprint, TextKit layout, grid scrolling, input-to-visible latency, or main-thread commit duration. Those remain AppKit/UI performance work. Controlling the Instruments app or running UI automation requires the fresh computer-control approval described in the workspace instructions before a control session begins. Headless builds, this executable, CLI profiling, and CLI tests do not require that permission.
