# Worked example: analyzing a slow order-history query

This is a portfolio lab example. The schema, data volumes, and plan output
below are invented for a fictional lab database (`ORCLLAB`) to show the
analysis method end to end. The plan text is illustrative example output
written for this document, not a capture from any real database, production
or otherwise. The SQL techniques are standard Oracle and were reviewed for
correctness; nothing here was executed against a live Oracle instance.

The companion guide, `docs/execution-plan-guide.md`, explains the mechanics
(collecting plans, reading predicates, estimation errors). This document
applies it to one statement.

## The complaint

A reporting query that returns one customer's recent order history has
slowed from under a second to roughly 40 seconds. Nothing in the application
changed. The statement:

```sql
SELECT o.order_id,
       o.order_date,
       o.status,
       o.order_total
FROM   orders o
WHERE  o.customer_id = 4821
AND    o.order_date >= DATE '2025-06-01'
ORDER  BY o.order_date DESC;
```

Relevant fictional schema facts:

- `orders`: about 12 million rows, roughly 60,000 customers, so an average
  customer has about 200 orders across all history.
- `orders(customer_id)` has a plain B-tree index, `ORD_CUST_IDX`.
- Customer 4821 is not average: it is a wholesale account with about
  480,000 orders, 4 percent of the table.
- Table and index statistics were gathered once, long ago, and the table
  has grown since.

## Step 1: get the actual plan

Following the guide, run the statement with plan statistics and pull the
plan from the cursor cache:

```sql
ALTER SESSION SET statistics_level = ALL;

SELECT /*+ gather_plan_statistics */ o.order_id, o.order_date, o.status,
       o.order_total
FROM   orders o
WHERE  o.customer_id = 4821
AND    o.order_date >= DATE '2025-06-01'
ORDER  BY o.order_date DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));
```

Illustrative example of what that output looks like for the bad run:

```
| Id | Operation                       | Name         | Starts | E-Rows | A-Rows | A-Time     | Buffers |
|----|---------------------------------|--------------|--------|--------|--------|------------|---------|
|  0 | SELECT STATEMENT                |              |      1 |        |     12 | 00:00:41.07|   2891K |
|  1 |  SORT ORDER BY                  |              |      1 |    103 |     12 | 00:00:41.07|   2891K |
|* 2 |   TABLE ACCESS BY INDEX ROWID   | ORDERS       |      1 |    103 |     12 | 00:00:40.92|   2891K |
|* 3 |    INDEX RANGE SCAN             | ORD_CUST_IDX |      1 |    103 | 481204 | 00:00:19.44|   2044K |

Predicate Information (identified by operation id):
   2 - filter("O"."ORDER_DATE" >= DATE '2025-06-01')
   3 - access("O"."CUSTOMER_ID" = 4821)
```

## Step 2: read it

Three observations, in the order the guide prescribes:

1. **Estimation failure at step 3.** The optimizer estimated 103 rows for
   customer 4821 (the flat average: 12 million rows, 60,000 customers,
   adjusted by density). Reality is 481,204 rows. The estimate is off by
   more than three orders of magnitude because the data is skewed and
   there is no histogram on `customer_id` to tell the optimizer that this
   particular value is exceptional. Note also that the E-Rows estimate rests
   on statistics old enough that the table was much smaller.

2. **The index plan multiplies the damage.** An index range scan returning
   103 rows is cheap. One returning 481,204 rows means 481,204 rowid
   lookups against the table (step 2, started once, executed per row):
   2.89 million buffer visits to end with 12 rows that survive the date
   filter. Nearly all of the 41 seconds is step 2 discarding rows.

3. **The selective predicate is a filter, not an access condition.** The
   `order_date` condition appears under step 2 as a filter. It is applied
   only after each row is fetched from the table. The plan does the
   expensive part (row visits) before the selective part (date check).

The root cause is information, not the index: the optimizer picked a
reasonable plan for the query it *thought* it was running (fetch about 100
rows by index) and a poor plan for the query it actually ran.

## Step 3: fix the information, then re-check

First action: refresh statistics and give the optimizer a histogram on the
skewed column.

```sql
EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname => 'LABAPP', tabname => 'ORDERS', -
     method_opt => 'FOR COLUMNS customer_id SIZE 254', -
     estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE);
```

With accurate counts and a histogram, the same statement produces a
different, and much cheaper, plan. Illustrative example output:

```
| Id | Operation          | Name   | Starts | E-Rows | A-Rows | A-Time     | Buffers |
|----|--------------------|--------|--------|--------|--------|------------|---------|
|  0 | SELECT STATEMENT   |        |      1 |        |     12 | 00:00:00.61|    9204 |
|  1 |  SORT ORDER BY     |        |      1 |  46012 |     12 | 00:00:00.61|    9204 |
|* 2 |   TABLE ACCESS FULL| ORDERS |      1 |  46012 |     12 | 00:00:00.59|    9197 |

Predicate Information (identified by operation id):
   2 - filter("O"."CUSTOMER_ID" = 4821 AND "O"."ORDER_DATE" >= DATE '2025-06-01')
```

Now the estimate for this customer is in the right range, the optimizer
knows an index-driven plan would mean hundreds of thousands of row visits,
and it chooses a full scan with multiblock reads instead: about 9,200
buffer visits and well under a second. A full scan is not a failure state.
On skewed data it is frequently the correct answer.

## Step 4: the structural option, and when to take it

Statistics fixed the incident. Whether anything else is warranted depends
on how often this query shape runs:

- If date-ordered lookups for large customers are a recurring pattern, a
  composite index on `(customer_id, order_date)` lets Oracle reach the
  qualifying rows inside the index and return them in date order, removing
  both the row-visit cost and the sort. That is real storage and write
  overhead on a 12-million-row table, justified by a recurring workload,
  not by one incident.
- If the pattern is rare, refreshed statistics and the histogram are the
  fix, and the composite index is unjustified weight on every insert.

The mistake to avoid is reaching for the index (or a hint) before fixing
the statistics. With the old statistics, a hint forcing the full scan
would have "fixed" this customer and quietly hurt every small customer
whose index plan was correct all along.

## What this example demonstrates

- Actual plans (A-Rows) over predicted plans when diagnosing a regression.
- Skew plus missing histograms as a root cause, found by comparing E-Rows
  to A-Rows at the step where they diverge.
- Reading predicates to see which conditions do access work and which only
  filter after the fact.
- Fixing optimizer information before changing structures or forcing
  plans, and judging a full table scan on evidence rather than reflex.

## Licensing note

The `gather_plan_statistics` workflow and ASH data referenced by this
material relate to the Oracle Diagnostics Pack. See
`docs/execution-plan-guide.md` for details on which parts require that
license and what to use without it.
