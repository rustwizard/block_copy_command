-- Upgrade block_copy_command from 0.1.4 to 0.1.5
-- Adds the audit_log table and block_copy_command.audit_log_enabled GUC.

CREATE SCHEMA IF NOT EXISTS block_copy_command;

CREATE TABLE block_copy_command.audit_log (
    id                bigserial   NOT NULL,
    ts                timestamptz NOT NULL DEFAULT clock_timestamp(),
    session_user_name text        NOT NULL,
    current_user_name text        NOT NULL,
    query_text        text        NOT NULL,
    copy_direction    text        NOT NULL,
    copy_is_program   bool        NOT NULL DEFAULT false,
    client_addr       inet,
    application_name  text,
    blocked           bool        NOT NULL,
    block_reason      text,
    PRIMARY KEY (id)
);

CREATE INDEX ON block_copy_command.audit_log (ts);
CREATE INDEX ON block_copy_command.audit_log (current_user_name);
CREATE INDEX ON block_copy_command.audit_log (ts) WHERE blocked;

REVOKE ALL ON SCHEMA block_copy_command FROM PUBLIC;
REVOKE ALL ON block_copy_command.audit_log FROM PUBLIC;
