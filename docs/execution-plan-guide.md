# Reading an execution plan

An execution plan is Oracle's own account of how a statement will run, or how
it actually ran. Guessing at a slow query without one is slow work. This guide
covers how to get a real plan, how to read it, and what the common problems
look like once you can.

Everything here uses a fictional lab schema (`ORCLLAB`) with invented table
and column names. The SQL and the DBMS_XPLAN calls are standard Oracle and
were reviewed for correctness, but they were not executed against a live
Oracle instance for this document. Treat the techniques as reference material
to run in your own environment.

## Getting a plan: predicted vs actual

There are two kinds of plan, and confusing them wastes time.

**Predicted plan** (EXPLAIN PLAN) shows what the optimizer *thinks* it will
do, based on statistics. It does not run the statement, so it cannot tell you
how many rows each step actually produced.

```sql
EXPLAIN PLAN FOR
SELECT c.customer_name, SUM(o.order_total)
FROM   orders o
JOIN   customers c ON c.customer_id = o.customer_id
WHERE  o.order_date >= DATE '2026-01-01'
GROUP  BY c.customer_name;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY());
```

**Actual plan** (DISPLAY_CURSOR) shows what *really happened* the last time
the statement ran: actual rows per step, actual time, buffer gets, reads.
For tuning work, this is the one that matters. A plan that looks fine on
paper and runs badly is a statistics or estimation problem, and only the
actual plan shows it.

```sql
-- Run the statement first, with statistics gathering enabled:
ALTER SESSION SET statistics_level = ALL;

SELECT /*+ gather_plan_statistics */ c.customer_name, SUM(o.order_total)
FROM   orders o
JOIN   customers c ON c.customer_id = o.customer_id
WHERE  o.order_date >= DATE '2026-01-01'
GROUP  BY c.customer_name;

-- Then pull the plan for the statement just executed:
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));
```

Useful format options for `DISPLAY_CURSOR`:

| Format | What it adds |
|---|---|
| `ALLSTATS LAST` | Starts, actual rows (A-Rows), time, buffer gets, reads for the last execution |
| `+PREDICATE` | Shows access and filter predicates per operation (also in ALLSTATS output) |
| `+PEEKED_BINDS` | Shows bind values the optimizer peeked at when it chose the plan |
| `+OUTLINE` | The full hint set that would reproduce this plan |
| `+PROJECTION` | Columns each step produces |

`DBMS_XPLAN.DISPLAY` (no suffix) reads the plan table written by EXPLAIN
PLAN. `DBMS_XPLAN.DISPLAY_CURSOR` reads the cursor cache. They are not
interchangeable: if you explained it, use DISPLAY; if it ran, use
DISPLAY_CURSOR.

There is also `DBMS_XPLAN.DISPLAY_AWR`, which pulls a plan for a SQL_ID from
the AWR repository. That is how you examine the plan a statement used during
an incident last Tuesday, after the cursor has aged out of memory.

## Licensing note

`DISPLAY_CURSOR` itself is not a licensed feature; execution plans from the
cursor cache are available on any edition. However:

- `DBMS_XPLAN.DISPLAY_AWR` reads AWR data and requires the Oracle
  Diagnostics Pack license.
- The `gather_plan_statistics` hint and `statistics_level = ALL` rely on the
  same runtime statistics collection used by ASH, which is part of the
  Diagnostics Pack.

On a database that is not licensed for Diagnostics Pack, use EXPLAIN PLAN
and `V$SQL_PLAN` (which is unlicensed) and expect predicted rows only.

## How to read the plan

Read order first, numbers second.

### 1. Find the shape

Plans are indented trees. A child step feeds its parent. Execution generally
starts with the most deeply indented step at the top of a branch and works
upward, but the reliable way to follow it is the parent-child relationship
shown by the Id column, not indentation alone.

Start by finding where rows first come from: the access paths at the leaves.
Then follow how they combine (joins), then what happens on top (sorts,
aggregation, filters).

### 2. Access paths: how Oracle reaches the rows

| Operation | Meaning | Watch for |
|---|---|---|
| `TABLE ACCESS FULL` | Full table scan: reads every block | Fine for small tables or when most rows qualify. Suspicious on a large table when the query only needs a few rows. |
| `TABLE ACCESS BY INDEX ROWID` | Row lookup by rowid from an index | Good when selective. Expensive when the index returns many rows, because each one is a separate table visit. |
| `INDEX RANGE SCAN` | Ordered walk of an index range | The workhorse selective access path. Check the predicates match the leading index columns. |
| `INDEX FULL SCAN` | Reads the whole index in order | Sometimes chosen to satisfy an ORDER BY or to avoid visiting the table at all. |
| `INDEX FAST FULL SCAN` | Reads the whole index with multiblock reads, unordered | Used when all needed columns are in the index and order does not matter. |
| `INDEX SKIP SCAN` | Treats a composite index as several smaller indexes | Appears when the leading column has few distinct values and a later column is selective. |

### 3. Join methods: how row sources combine

| Operation | Strengths | Watch for |
|---|---|---|
| `NESTED LOOPS` | Fast for small outer results driving selective index lookups on the inner side | Blows up when the outer side returns far more rows than estimated; each row costs an index probe. |
| `HASH JOIN` | Handles larger, less selective joins well; one pass over each side | Needs memory (PGA); can spill to temp and get slow. A hash join on a query expected to be a quick lookup is a smell. |
| `MERGE JOIN` | Good when both inputs arrive sorted or need sorting anyway | Sorting large inputs is the cost; check whether ORDER BY made it look attractive. |
| `CARTESIAN` | Joins every row to every row | Almost always a missing join condition or missing statistics. Treat as a red flag until proven intentional. |

### 4. The numbers that matter

For each step, compare estimate against reality:

- **E-Rows (Rows in older formats):** what the optimizer estimated.
- **A-Rows:** what actually happened. The single most useful column in the
  plan. When A-Rows and E-Rows diverge by an order of magnitude at some
  step, everything above that step was planned with wrong information:
  stale statistics, a skewed column with no histogram, a function wrapped
  around an indexed column, or bind peeking on a skewed value.
- **Buffers:** logical reads. High buffer counts on a step mean repeated
  block visits, usually an index-driven plan touching far more rows than
  expected.
- **Reads:** physical reads. Sustained high reads with low output rows
  point at poor clustering or an unselective access path.
- **A-Time:** cumulative elapsed time. Work top-down: the step consuming
  the time is usually a child of the step where A-Time jumps.
- **Cost:** the optimizer's internal unit for comparing candidate plans.
  It is useful for comparing two plans for the same statement. It is not a
  runtime prediction and comparing cost across different statements (or
  databases) means nothing.

### 5. Predicates

Always read the Predicate Information section. Two columns matter:

- **access(...):** conditions used to drive the access path itself (index
  keys, join conditions). This is the selective work.
- **filter(...):** conditions applied after rows are fetched. Rows read and
  then discarded by a filter are wasted work. If the bulk of a query's
  filtering happens in filter() predicates on a full scan, ask whether an
  index on those columns, or better statistics, would let the optimizer do
  the filtering as access instead.

A classic trap: `filter(TO_CHAR(order_date) = '2026-01-01')`. The function
hides the column from the index and from statistics. The fix is to rewrite
the predicate so the column stands alone, not to add hints.

## A short working method

1. Get the actual plan (DISPLAY_CURSOR, ALLSTATS LAST) for the slow
   statement, not an EXPLAIN PLAN approximation.
2. Find the first step, reading top-down, where A-Rows departs badly from
   E-Rows. That is where the optimizer's picture of the data broke.
3. Check the predicates under that step. Function-wrapped columns, implicit
   type conversions (look for `SYS_OP_C2C` or internal conversion notes in
   newer versions), and missing histograms live here.
4. Check statistics on the tables and indexes involved: last analyzed date,
   and whether the filtered columns are skewed. Fix information before
   fixing the plan.
5. Only then consider structural fixes: a better index, a rewrite, or (as a
   documented, last-resort measure) a plan management mechanism such as a
   SQL profile or SQL plan baseline to hold a known-good plan in place.

Hints belong in diagnosis (forcing an alternative plan to test a hypothesis)
far more than they belong in production code. A hint that wins today fights
the optimizer on every future statistics change.

## Common findings, in plain terms

- **Nested loops with a huge A-Rows on the outer side:** underestimated
  outer result; inner index probes multiplied. Look at statistics on the
  outer table's filter columns.
- **Hash join where a lookup was expected:** the optimizer judged the join
  unselective, often correctly. Verify with A-Rows before "fixing" it.
- **Full scan of the biggest table in the query:** either genuinely the
  cheapest path (most rows qualify) or the selective index path was
  rejected because of stale statistics, a low clustering factor, or a
  predicate the index cannot serve.
- **Sort spilling (look at temp usage in extended statistics output, or a
  much higher A-Time than CPU suggests):** undersized work area for this
  execution, or far more rows sorted than estimated.
- **Buffers in the millions, A-Rows in the dozens:** the plan visits blocks
  repeatedly to discard almost everything. The filter predicates tell you
  what it is discarding and why the access path could not avoid fetching
  it.

## Related material in this repo

- `docs/awr-ash-concepts.md`: where the historical data behind incident
  plans comes from, and AWR vs ASH retention.
- `docs/plan-analysis-example.md`: this guide applied to one fictional
  statement, start to finish.
- `docs/high-cpu-runbook.md`: what to do when the symptom is CPU, before
  you ever get to an individual plan.
