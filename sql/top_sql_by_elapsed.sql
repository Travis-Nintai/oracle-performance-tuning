-- ============================================================================
-- top_sql_by_elapsed.sql
--
-- Purpose:
--   Lists the most expensive SQL statements by total elapsed time within an
--   AWR snapshot range. The starting point for "the database was slow
--   between X and Y" -- find what consumed the time first, tune second.
--
-- Usage:
--   sqlplus / as sysdba @top_sql_by_elapsed.sql
--
--   Snapshot range: edit the DEFINEs below, or leave both at 0 to use the
--   two most recent snapshots automatically.
--
--   To find snapshot IDs for an incident window:
--     SELECT snap_id, begin_interval_time, end_interval_time
--       FROM dba_hist_snapshot
--      ORDER BY snap_id DESC;
--
-- Notes:
--   - AWR views (DBA_HIST_*) require the Oracle Diagnostics Pack license.
--   - Read-only. Exit code is always 0; this is a diagnostic listing.
-- ============================================================================

SET ECHO OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET PAGESIZE 100
SET LINESIZE 160
SET TRIMSPOOL ON
SET TAB OFF

-- ----------------------------------------------------------------------------
-- Snapshot range. 0 / 0 = the two most recent snapshots.
-- Number of rows in the report.
-- ----------------------------------------------------------------------------
DEFINE begin_snap = 0
DEFINE end_snap   = 0
DEFINE top_n      = 20

-- ----------------------------------------------------------------------------
-- Resolve the snapshot range (explicit IDs, or latest two when 0).
-- ----------------------------------------------------------------------------
COLUMN b_snap_id NOPRINT NEW_VALUE v_begin_snap
COLUMN e_snap_id NOPRINT NEW_VALUE v_end_snap
COLUMN b_time    NOPRINT NEW_VALUE v_begin_time
COLUMN e_time    NOPRINT NEW_VALUE v_end_time

SELECT CASE WHEN &begin_snap = 0 THEN s.prev_snap ELSE &begin_snap END AS b_snap_id,
       CASE WHEN &end_snap   = 0 THEN s.last_snap ELSE &end_snap   END AS e_snap_id,
       TO_CHAR(b.begin_interval_time, 'YYYY-MM-DD HH24:MI')           AS b_time,
       TO_CHAR(e.end_interval_time,   'YYYY-MM-DD HH24:MI')           AS e_time
  FROM (SELECT MAX(snap_id)     AS last_snap,
               MAX(snap_id) - 1 AS prev_snap
          FROM dba_hist_snapshot
         WHERE dbid            = (SELECT dbid FROM v$database)
           AND instance_number = (SELECT instance_number FROM v$instance)) s
  LEFT JOIN dba_hist_snapshot b
    ON b.snap_id =
         CASE WHEN &begin_snap = 0 THEN s.prev_snap ELSE &begin_snap END
   AND b.dbid            = (SELECT dbid FROM v$database)
   AND b.instance_number = (SELECT instance_number FROM v$instance)
  LEFT JOIN dba_hist_snapshot e
    ON e.snap_id =
         CASE WHEN &end_snap = 0 THEN s.last_snap ELSE &end_snap END
   AND e.dbid            = (SELECT dbid FROM v$database)
   AND e.instance_number = (SELECT instance_number FROM v$instance);

PROMPT Top SQL by elapsed time: snapshots &v_begin_snap (&v_begin_time) to &v_end_snap (&v_end_time)
PROMPT

COLUMN sql_id      FORMAT A13          HEADING 'SQL ID'
COLUMN sql_text    FORMAT A50          HEADING 'SQL TEXT'
COLUMN execs       FORMAT 999,999,990  HEADING 'EXECS'
COLUMN elapsed_sec FORMAT 999,999,990  HEADING 'ELAPSED|SEC'
COLUMN cpu_sec     FORMAT 999,999,990  HEADING 'CPU|SEC'
COLUMN avg_ms      FORMAT 999,990.0    HEADING 'AVG MS|PER EXEC'
COLUMN pct_total   FORMAT 990.0        HEADING '% OF|TOTAL'

SELECT * FROM (
  SELECT st.sql_id,
         SUBSTR(txt.sql_text, 1, 50)                                       AS sql_text,
         SUM(st.executions_delta)                                          AS execs,
         ROUND(SUM(st.elapsed_time_delta) / 1000000)                       AS elapsed_sec,
         ROUND(SUM(st.cpu_time_delta) / 1000000)                           AS cpu_sec,
         ROUND(SUM(st.elapsed_time_delta) / 1000
               / NULLIF(SUM(st.executions_delta), 0), 1)                   AS avg_ms,
         ROUND(RATIO_TO_REPORT(SUM(st.elapsed_time_delta)) OVER () * 100, 1) AS pct_total
    FROM dba_hist_sqlstat st
    JOIN dba_hist_sqltext txt
      ON txt.sql_id = st.sql_id
     AND txt.dbid   = st.dbid
   WHERE st.dbid            = (SELECT dbid FROM v$database)
     AND st.instance_number = (SELECT instance_number FROM v$instance)
     AND st.snap_id BETWEEN &v_begin_snap AND &v_end_snap
   GROUP BY st.sql_id, SUBSTR(txt.sql_text, 1, 50)
   ORDER BY elapsed_sec DESC
) WHERE ROWNUM <= &top_n;

PROMPT
PROMPT Done. Diagnostic listing only -- exit 0.
EXIT 0
