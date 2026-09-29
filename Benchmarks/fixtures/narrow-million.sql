-- Eight columns, roughly 256 bytes of PostgreSQL text payload per row.
-- Pure SELECT: no tables, extensions, or database writes required.
SELECT i::bigint AS id,
       (i % 1000)::integer AS bucket,
       (i / 10.0)::numeric(20,4) AS exact_amount,
       (i % 2 = 0) AS enabled,
       CASE WHEN i % 10 = 0 THEN NULL::text ELSE ''::text END AS nullable_empty,
       repeat('x', 100) AS payload_a,
       repeat('y', 128) AS payload_b,
       'ação 🐘'::text AS unicode
FROM generate_series(1, 1000000) AS fixture(i);
