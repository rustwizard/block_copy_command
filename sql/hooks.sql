-- This extension registers a ProcessUtility hook in _PG_init to block COPY commands.
-- To activate for all connections, add to postgresql.conf:
--   shared_preload_libraries = 'block_copy_command'

CREATE SCHEMA IF NOT EXISTS block_copy_command;

-- Audit log for all intercepted COPY commands.
--
-- NOTE: for *blocked* commands the INSERT is performed before ERROR is raised,
-- so it will be rolled back when the current transaction aborts.  The server log
-- (LOG: blocked COPY ...) is the authoritative record for blocked events.
-- Allowed COPY commands commit normally and their rows persist here.
CREATE TABLE block_copy_command.audit_log (
    id                bigserial   NOT NULL,
    -- clock_timestamp() captures the actual wall-clock time; now() would give
    -- the transaction start time, which is the same row for every statement in
    -- a multi-statement transaction.
    ts                timestamptz NOT NULL DEFAULT clock_timestamp(),
    -- Both user fields are recorded because SET ROLE makes them diverge:
    -- session_user_name is who actually authenticated, current_user_name is the
    -- effective role at the time of the COPY.
    session_user_name text        NOT NULL,
    current_user_name text        NOT NULL,
    query_text        text        NOT NULL,
    copy_direction    text        NOT NULL,  -- 'TO' | 'FROM'
    copy_is_program   bool        NOT NULL DEFAULT false,
    -- inet_client_addr() returns NULL for local (Unix-socket) connections.
    client_addr       inet,
    application_name  text,
    blocked           bool        NOT NULL,
    -- NULL when not blocked; one of: 'role_listed', 'program_blocked',
    -- 'direction_blocked' when blocked.
    block_reason      text,
    PRIMARY KEY (id)
);

-- Index for time-range queries and dashboards.
CREATE INDEX ON block_copy_command.audit_log (ts);
-- Index for per-user audits.
CREATE INDEX ON block_copy_command.audit_log (current_user_name);
-- Partial index: fast scan of blocked-only events (typically a small fraction).
CREATE INDEX ON block_copy_command.audit_log (ts) WHERE blocked;

-- Lock down the schema and table; superusers can explicitly grant SELECT to
-- monitoring roles as needed.
REVOKE ALL ON SCHEMA block_copy_command FROM PUBLIC;
REVOKE ALL ON block_copy_command.audit_log FROM PUBLIC;
