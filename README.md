# Oracle Performance Tuning

When someone says "the database is slow," monitoring tells you something is wrong but rarely tells you why. This repo is the next step: finding the actual bottleneck, the SQL, the sessions, and the wait events behind a slow database, using Oracle's own performance data: AWR and ASH.

The scripts here are the first things to reach for on a slow-database call: what ran longest, who is active right now, and what they're waiting on. The docs cover the concepts behind them and a runbook for the most common case, unexplained high CPU.

## Who it's for

Oracle DBAs who already know their way around a database and want a repeatable way to work a performance problem, instead of guessing or restarting things and hoping.

## Layout

```
oracle-performance-tuning/
├── sql/    -- SQL*Plus diagnostic queries (AWR and ASH based)
└── docs/   -- concepts and troubleshooting runbooks
```

## Scripts

| Script | What it does |
|---|---|
| `sql/top_sql_by_elapsed.sql` | Top SQL by elapsed time in an AWR snapshot range; defaults to the two latest snapshots |
| `sql/top_sessions_ash.sql` | Most active sessions in the last N minutes from ASH, with wait events |

Top SQL for the default window (the two most recent snapshots):

```
sqlplus / as sysdba @sql/top_sql_by_elapsed.sql
```

For a specific incident window, set the snapshot IDs at the top of the script:

```
DEFINE begin_snap = 4121
DEFINE end_snap   = 4125
```

Who's active right now (15-minute default, edit the `DEFINE` to change it):

```
sqlplus / as sysdba @sql/top_sessions_ash.sql
```

Both are diagnostic listings: read-only, exit 0. If AWR vs ASH isn't
second nature yet, start with `docs/awr-ash-concepts.md`.

The decision process for a CPU spike is written up in
`docs/high-cpu-runbook.md`, host vs database, finding the sessions,
common causes, and what not to do.

Once a slow statement is identified, `docs/execution-plan-guide.md` covers
how to get its real execution plan with DBMS_XPLAN, how to read access
paths, join methods, and estimates against actual rows, and how to find
where the optimizer's picture of the data went wrong.
`docs/plan-analysis-example.md` applies that method to one fictional lab
statement end to end: a skewed column, a missing histogram, and an index
plan that falls apart at scale.

## Assumptions

- Oracle 11g or later. The AWR queries read `DBA_HIST_*`; the ASH query reads `V$ACTIVE_SESSION_HISTORY`.
- AWR and ASH both require the Oracle Diagnostics Pack license. The scripts say so in their headers. If the database isn't licensed for Diagnostics Pack, these views aren't available. Statspack is the free alternative, and the concepts in `docs/awr-ash-concepts.md` still mostly apply.
- Run as a user that can read the data dictionary and performance views (`/ as sysdba` works).
- Database names and values in examples are fictional lab values.

## Safety notes

- Everything here is read-only. No DML, no DDL, nothing that changes the database.
- AWR queries against a large `SYSAUX` can be slow on the first run; that's the repository being queried, not your workload.
- Never commit credentials, hostnames, or environment-specific details alongside these scripts.

## What this demonstrates

Performance diagnosis the way it actually happens: start from the symptom, use AWR to find the time window and the expensive SQL, use ASH to see what sessions are doing right now, and work from evidence instead of hunches.

## Background

Recreated from standard DBA practice for a personal lab portfolio, generic examples, not exports from any production environment.
