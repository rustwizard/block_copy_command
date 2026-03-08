# block_copy_command

A PostgreSQL extension that blocks `COPY` commands by installing a `ProcessUtility` hook.

## How it works

When loaded via `shared_preload_libraries`, the extension registers a hook into PostgreSQL's utility command processing pipeline. `COPY` statements are intercepted before execution according to the following priority:

1. If the role is listed in `block_copy_command.blocked_roles` → **always blocked**, even superusers
2. If `block_copy_command.block_program = on` and the statement is `COPY TO/FROM PROGRAM` → **always blocked**, even superusers
3. If `block_copy_command.enabled = off` → allowed (for roles not in the blocklist)
4. If the user is a superuser → **allowed** (bypass)
5. Otherwise, direction is checked: `block_copy_command.block_to` and `block_copy_command.block_from`

```
ERROR:  COPY TO command is not allowed
ERROR:  COPY FROM command is not allowed
ERROR:  COPY TO PROGRAM command is not allowed
```

All other SQL commands (DDL, DML, queries) are unaffected and pass through to the standard handler.

## Requirements

- PostgreSQL 13–18
- Built with [pgrx](https://github.com/pgcentralfoundation/pgrx) 0.17.0

## Installation

### Build from source

```bash
cargo install cargo-pgrx --version 0.17.0 --locked
cargo pgrx init --pg17 download   # or point to your system pg_config
cargo pgrx package --features pg17
```

Install the produced files:

```bash
cp target/release/block_copy_command-pg17/usr/lib/postgresql/17/lib/block_copy_command.so \
   $(pg_config --pkglibdir)/
cp target/release/block_copy_command-pg17/usr/share/postgresql/17/extension/block_copy_command* \
   $(pg_config --sharedir)/extension/
```

### Enable the extension

Add to `postgresql.conf`:

```
shared_preload_libraries = 'block_copy_command'
```

Restart PostgreSQL, then in any database where you want the extension registered:

```sql
CREATE EXTENSION block_copy_command;
```

> **Note:** The hook is active for the entire cluster as soon as the library is loaded — `CREATE EXTENSION` only registers the extension metadata.

## Usage

### Blocking behaviour

COPY is blocked for non-superusers by default:

```sql
-- as a regular user:
COPY my_table TO STDOUT;
-- ERROR:  COPY TO command is not allowed

COPY my_table FROM STDIN;
-- ERROR:  COPY FROM command is not allowed

COPY (SELECT * FROM my_table) TO '/tmp/out.csv';
-- ERROR:  COPY TO command is not allowed
```

Superusers are bypassed unless explicitly listed in `block_copy_command.blocked_roles` or unless `block_copy_command.block_program = on`:

```sql
-- as a superuser (not in blocked_roles):
COPY (SELECT 1) TO STDOUT;
-- 1

-- COPY TO PROGRAM is blocked for everyone by default:
COPY (SELECT 1) TO PROGRAM 'cat';
-- ERROR:  COPY TO PROGRAM command is not allowed
```

### GUC: `block_copy_command.enabled`

Toggles the block for non-superusers at runtime. Only superusers can change this setting.

| Value | Effect |
|-------|--------|
| `on` (default) | COPY blocked for non-superusers (subject to `block_to`/`block_from`) |
| `off` | COPY allowed (roles not in `blocked_roles`) |

**Per-role** (takes effect on next connection):

```sql
ALTER ROLE etl_user SET block_copy_command.enabled = off;

-- revert
ALTER ROLE etl_user RESET block_copy_command.enabled;
```

**Per-database:**

```sql
ALTER DATABASE mydb SET block_copy_command.enabled = off;
```

**Per-session** (superuser only):

```sql
SET block_copy_command.enabled = off;
COPY ...;
SET block_copy_command.enabled = on;
```

### GUC: `block_copy_command.block_to`

Controls whether `COPY TO` (export) is blocked for non-superusers. Only evaluated when `enabled = on`. Only superusers can change this setting.

| Value | Effect |
|-------|--------|
| `on` (default) | `COPY TO` blocked for non-superusers |
| `off` | `COPY TO` allowed for non-superusers |

**Typical ETL pattern** — allow import, block export:

```sql
-- Allow COPY FROM (import) for etl_user, keep COPY TO blocked
ALTER ROLE etl_user SET block_copy_command.block_from = off;
```

### GUC: `block_copy_command.block_from`

Controls whether `COPY FROM` (import) is blocked for non-superusers. Only evaluated when `enabled = on`. Only superusers can change this setting.

| Value | Effect |
|-------|--------|
| `on` (default) | `COPY FROM` blocked for non-superusers |
| `off` | `COPY FROM` allowed for non-superusers |

### GUC: `block_copy_command.block_program`

Blocks `COPY TO PROGRAM` and `COPY FROM PROGRAM` for **all users**, including superusers. This prevents shell command execution via COPY. Only superusers can change this setting.

| Value | Effect |
|-------|--------|
| `on` (default) | `COPY ... PROGRAM` blocked for everyone |
| `off` | `COPY ... PROGRAM` allowed (subject to other rules) |

```sql
-- Temporarily allow COPY TO PROGRAM for a superuser session:
SET block_copy_command.block_program = off;
COPY (SELECT 1) TO PROGRAM 'cat';
SET block_copy_command.block_program = on;
```

### GUC: `block_copy_command.blocked_roles`

A comma-separated list of role names that are **always** blocked from running `COPY`, regardless of superuser status or the `enabled` setting. Only superusers can change this setting.

```sql
-- block a specific superuser
SET block_copy_command.blocked_roles = 'alice';
COPY (SELECT 1) TO STDOUT;  -- blocked even if alice is a superuser

-- block multiple roles
SET block_copy_command.blocked_roles = 'alice, bob, etl_user';
```

**Per-role** (takes effect on next connection):

```sql
ALTER ROLE alice SET block_copy_command.blocked_roles = 'alice';

-- revert
ALTER ROLE alice RESET block_copy_command.blocked_roles;
```

### Audit logging

When a COPY command is blocked, the current username is written to the PostgreSQL server log at `LOG` level:

```
LOG:  current_user = "someuser"
ERROR:  COPY TO command is not allowed
```

## Testing

### With Docker (recommended)

```bash
docker compose up --build --abort-on-container-exit --exit-code-from test
```

This builds the extension inside Docker, starts a PostgreSQL 17 instance with the extension loaded, and runs the integration test suite covering:

- COPY TO and COPY FROM blocked for non-superusers (default)
- Direction-specific errors (`COPY TO command is not allowed` / `COPY FROM command is not allowed`)
- `block_from=off`: allows COPY FROM while keeping COPY TO blocked
- `block_to=off`: allows COPY TO while keeping COPY FROM blocked
- `block_program=on`: COPY TO/FROM PROGRAM blocked even for superusers
- Superuser bypass
- GUC `block_copy_command.enabled` toggle
- GUC `block_copy_command.blocked_roles` blocks specific roles including superusers
- DDL, DML, and regular queries unaffected

### With pgrx test runner

```bash
cargo pgrx test pg17
```

Runs the unit tests embedded in the source using pgrx's own managed PostgreSQL instance.

## License

See [LICENSE](LICENSE).
