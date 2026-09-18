-- ============================================================================
-- top_sessions_ash.sql
--
-- Purpose:
--   Shows the most active sessions over a recent window from Active Session
--   History: which sessions are consuming database time, and whether that
--   time is going to CPU or to a specific wait event. Answers "what is the
--   database doing right now?"
--
-- Usage:
--   sqlplus / as sysdba @top_sessions_ash.sql
--
--   Window: edit DEFINE lookback_min below (default: last 15 minutes).
--
-- Notes:
--   - V$ACTIVE_SESSION_HISTORY is an in-memory buffer; how far back it
--     reaches depends on activity. On a busy system it may only cover the
--     last few minutes -- if the window you need has aged out, query AWR
--     (DBA_HIST_ACTIVE_SESS_HISTORY) for that time range instead.
--   - ASH requires the Oracle Diagnostics Pack license.
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
-- Lookback window in minutes. Number of rows per report section.
-- ----------------------------------------------------------------------------
DEFINE lookback_min = 15
DEFINE top_n        = 20

PROMPT Top active sessions - last &lookback_min minutes
PROMPT

COLUMN session_id     FORMAT 9999990   HEADING 'SID'
COLUMN session_serial# FORMAT 9999990  HEADING 'SERIAL#'
COLUMN username       FORMAT A20       HEADING 'USERNAME'
COLUMN event          FORMAT A40       HEADING 'EVENT'
COLUMN samples        FORMAT 999,999   HEADING 'SAMPLES'
COLUMN pct_active     FORMAT 990.0      HEADING '% ACTIVE'

SELECT * FROM (
  SELECT a.session_id,
         a.session_serial#,
         NVL(s.username, u.username)                              AS username,
         DECODE(a.session_state, 'ON CPU', 'ON CPU', a.event)      AS event,
         COUNT(*)                                                 AS samples,
         ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 1)          AS pct_active
    FROM v$active_session_history a
    LEFT JOIN v$session s
      ON s.sid     = a.session_id
     AND s.serial# = a.session_serial#
    LEFT JOIN dba_users u
      ON u.user_id = a.user_id
   WHERE a.sample_time  > SYSDATE - (&lookback_min / 1440)
     AND a.session_type = 'FOREGROUND'
   GROUP BY a.session_id,
            a.session_serial#,
            NVL(s.username, u.username),
            DECODE(a.session_state, 'ON CPU', 'ON CPU', a.event)
   ORDER BY samples DESC
) WHERE ROWNUM <= &top_n;

PROMPT
PROMPT Top wait events - last &lookback_min minutes
PROMPT

COLUMN event      FORMAT A40  HEADING 'EVENT'
COLUMN wait_class FORMAT A18  HEADING 'WAIT CLASS'
COLUMN samples    FORMAT 999,999 HEADING 'SAMPLES'
COLUMN pct_active FORMAT 990.0   HEADING '% ACTIVE'

SELECT * FROM (
  SELECT DECODE(a.session_state, 'ON CPU', 'ON CPU', a.event) AS event,
         a.wait_class                                        AS wait_class,
         COUNT(*)                                            AS samples,
         ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 1)     AS pct_active
    FROM v$active_session_history a
   WHERE a.sample_time  > SYSDATE - (&lookback_min / 1440)
     AND a.session_type = 'FOREGROUND'
   GROUP BY DECODE(a.session_state, 'ON CPU', 'ON CPU', a.event),
            a.wait_class
   ORDER BY samples DESC
) WHERE ROWNUM <= &top_n;

PROMPT
PROMPT Done. Diagnostic listing only -- exit 0.
EXIT 0
