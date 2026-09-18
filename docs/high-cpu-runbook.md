# High CPU troubleshooting runbook

For the most common performance page: host CPU is pegged and everything
is slow. Work top-down — host, then database, then the specific SQL —
and don't skip steps.

## 1. Is the CPU pressure even from Oracle?

Check the host first. `top` / `vmstat`: is it user CPU or iowait? A
database waiting on storage looks like high CPU from the application
side, but the fix is I/O, not the database.

- High user CPU with Oracle processes on top: the database is burning
  CPU. Continue below.
- High iowait: storage or I/O subsystem problem — different runbook.
- Run queue (`vmstat` `r` column) consistently above the vCPU count: the
  host is genuinely oversubscribed.

Rule out non-Oracle consumers on the box before blaming the database:
backups, monitoring agents, and batch jobs on shared hosts cause most
of the false alarms.

## 2. Find what the database is doing right now

```
sqlplus / as sysdba @sql/top_sessions_ash.sql
```

This shows the most active sessions over the last 15 minutes and whether
their time is going to CPU or to a wait event. Two patterns cover most
cases:

- **One or a few sessions on CPU, running the same SQL** — a runaway
  query. Take the SQL ID from the output and pull its execution plan.
- **Many sessions waiting on the same event** (latches, locks, I/O) —
  contention, not CPU. The CPU spike is a symptom of sessions spinning
  while they wait. Chase the wait event, not the CPU.

If the spike already passed, the ASH in-memory buffer may not reach back
far enough — use AWR (`DBA_HIST_ACTIVE_SESS_HISTORY`) for the incident
window instead.

## 3. Common causes, roughly in order of likelihood

- **Execution plan change.** The classic: a query that ran fine for a
  year picks a new plan after statistics gathering or a bind-variable
  issue. Compare the current plan to the last known good one
  (`DBA_HIST_SQL_PLAN`); if it flipped, stabilize the good plan with a
  baseline rather than rewriting the query at 2 AM.
- **Stale or missing optimizer statistics.** New data, no stats, bad
  cardinality estimates, bad plans. Check
  `DBA_TAB_STATISTICS.LAST_ANALYZED` on the objects in the offending SQL.
- **Runaway parallel query.** A degree set too high (or a hint) can
  saturate every CPU on the box. `PX`-family wait events with dozens of
  parallel slaves on one SQL ID is the signature.
- **Excessive hard parsing.** High CPU with `library cache` waits and a
  flood of distinct SQL IDs usually means literals instead of binds —
  an application problem, fixed in code rather than in the database.
- **Batch or job overlap.** Two heavy jobs that used to run serially now
  overlap after a schedule change. AWR across the incident window shows
  this immediately.

## 4. What not to do

- **Don't kill sessions blindly.** Killing the victims of contention
  accomplishes nothing; killing the one runaway without understanding
  it means it's back on the next run. Identify first, act second.
- **Don't bounce the database.** It clears the evidence (ASH buffer,
  shared pool) and the problem returns with the next workload cycle.
- **Don't gather statistics in the middle of the incident** unless stale
  stats are the known cause — new stats mean new plans, which can make
  things worse while everyone is watching.
- **Don't add CPUs as the first response.** One bad plan burning 32
  cores will burn 64 too.

## 5. Verify the fix

Re-run the same queries after the change — same data source, same window
shape. OS CPU back to normal plus the offending SQL dropping out of the
top-elapsed list is a verified fix. "It feels faster" is not.

## 6. Escalation

Bring in the application team when the fix lives in code or SQL they own
(missing bind variables, a runaway report query, a deployment that lines up
with the spike). Open an Oracle Support SR when SQL and workload are
ruled out and the time is going somewhere unaccounted for — collect
first: the AWR range covering the incident, ASH data, the alert log,
and OS statistics, so the SR starts with evidence instead of a
description.
