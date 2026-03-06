# block_copy_command

A PostgreSQL extension that blocks all `COPY` commands cluster-wide by installing a `ProcessUtility` hook.

## How it works

When loaded via `shared_preload_libraries`, the extension registers a hook into PostgreSQL's utility command processing pipeline. Any attempt to execute a `COPY` statement — regardless of direction (`TO` / `FROM`), user, or target — is intercepted before execution and raises an error:

```
ERROR:  COPY command is not allowed
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
# paths printed by cargo pgrx package
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

Once loaded, any `COPY` command will be rejected:

```sql
COPY my_table TO STDOUT;
-- ERROR:  COPY command is not allowed

COPY my_table FROM STDIN;
-- ERROR:  COPY command is not allowed

COPY (SELECT * FROM my_table) TO '/tmp/out.csv';
-- ERROR:  COPY command is not allowed
```

## Testing

### With Docker (recommended)

```bash
docker compose up --build --abort-on-container-exit --exit-code-from test
```

This builds the extension inside Docker, starts a PostgreSQL 17 instance with the extension loaded, and runs the integration test suite.

### With pgrx test runner

```bash
cargo pgrx test pg17
```

Runs the unit tests embedded in the source using pgrx's own managed PostgreSQL instance.

## License

See [LICENSE](LICENSE).
