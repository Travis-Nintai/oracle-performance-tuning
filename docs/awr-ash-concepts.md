# AWR and ASH: a practical guide

Two related but different data sources. Mixing them up is the most common
mistake people make when they start performance tuning, so this is worth
getting straight first.

Conceptual and educational, background reading for the scripts in `sql/`.

## AWR: what happened

The Automatic Workload Repository takes snapshots of database activity,
by default once an hour, and keeps them for 8 days. Both are configurable
with `DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS`. Each snapshot
captures cumulative counters: SQL execution stats, wait events, system
statistics, segment growth, and more. The history lives in `DBA_HIST_*`
views inside `SYSAUX`.

Think of AWR as the flight recorder: it tells you what the database did
between 2 PM and 3 PM yesterday, which is exactly what you need when the
complaint is "it was slow yesterday afternoon."

Key views:

- `DBA_HIST_SNAPSHOT`, the snapshot inventory. Every historical
  analysis starts by picking the right snapshot range here.
- `DBA_HIST_SQLSTAT`, per-SQL execution statistics per snapshot
  (elapsed time, CPU, I/O, executions). Deltas between snapshots give
  you what each SQL cost during the window.
- `DBA_HIST_SYSTEM_EVENT` / `DBA_HIST_SYSSTAT`, wait events and system
  statistics per snapshot.
- `DBA_HIST_ACTIVE_SESS_HISTORY`, ASH samples persisted to disk (one
  row per 10 seconds per active session), kept as long as AWR snapshots
  are retained.

## ASH: what is happening

Active Session History samples every active session once per second and
records what each session is doing at that instant, which SQL it's
running, whether it's on CPU or waiting, and on what event. The live
data sits in `V$ACTIVE_SESSION_HISTORY` in memory. How far back it
reaches depends on activity: on a busy system the buffer can be
overwritten within minutes, on a quiet one it may cover hours.

Think of ASH as looking over the database's shoulder right now: the
right tool for "it's slow *at this moment*, what's it doing?" and for
drilling into a specific session second by second.

Key views:

- `V$ACTIVE_SESSION_HISTORY`, the in-memory sample buffer.
- `V$SESSION`, join target for current session details (username,
  program, machine) on samples belonging to sessions still connected.

## When to use which

| Situation | Reach for |
|---|---|
| Slow right now | ASH, `sql/top_sessions_ash.sql` |
| Slow yesterday between 2 and 3 | AWR, pick snapshots, then `sql/top_sql_by_elapsed.sql` |
| Getting worse over weeks | AWR trending across snapshots |
| Which session is doing what, second by second | ASH |

## A sensible first pass on a slow-database complaint

1. Confirm the database is actually the problem. Check the host first,
   CPU run queues, memory pressure, I/O wait. A database doesn't get
   slow in isolation from its host.
2. Fix the time window. "Slow" is useless without "when." ASH if it's
   happening now, AWR snapshots if it already happened.
3. Find the expensive SQL. Rank by elapsed time in the window, elapsed,
   not CPU, because waits are usually where the time goes.
4. Find who's running it. ASH grouped by session and event shows whether
   it's one runaway session or many sessions queueing on the same thing.
5. Get the execution plan and compare it against the last known good
   plan. Most sudden slowdowns are plan changes, not data changes.
6. Fix the cause, then verify with the same queries, before and after
   from the same data source, or you're guessing.

## Licensing note

AWR and ASH are part of the Oracle Diagnostics Pack, a separately
licensed option. Querying `DBA_HIST_*` or `V$ACTIVE_SESSION_HISTORY` on
a database not licensed for it is a compliance problem, not a technical
one. The scripts in this repo note this in their headers. Where
Diagnostics Pack isn't available, Statspack, free, under
`$ORACLE_HOME/rdbms/admin`, covers similar ground with more effort.
