#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# psql as the superuser (postgres)
SU="psql"
# psql as a non-superuser
RU="psql -U testuser"

echo "=== Setting up ==="
psql -c "CREATE EXTENSION IF NOT EXISTS block_copy_command;"
psql -c "DROP OWNED BY testuser;" 2>/dev/null || true
psql -c "DROP ROLE IF EXISTS testuser;"
psql -c "CREATE ROLE testuser LOGIN PASSWORD 'testpass';"
psql -c "GRANT CONNECT ON DATABASE testdb TO testuser;"
export PGPASSWORD=postgres

echo ""
echo "=== Block for non-superuser (GUC enabled, default) ==="

echo ""
echo "--- Test 1: non-superuser COPY TO STDOUT is blocked ---"
out=$(PGPASSWORD=testpass $RU -c "COPY pg_class TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY TO command is not allowed"; then
    pass "non-superuser COPY TO STDOUT blocked"
else
    fail "non-superuser COPY TO STDOUT not blocked; got: $out"
fi

echo ""
echo "--- Test 2: non-superuser COPY FROM STDIN is blocked ---"
out=$(PGPASSWORD=testpass $RU -c "COPY pg_class FROM STDIN;" 2>&1 || true)
if echo "$out" | grep -q "COPY FROM command is not allowed"; then
    pass "non-superuser COPY FROM STDIN blocked"
else
    fail "non-superuser COPY FROM STDIN not blocked; got: $out"
fi

echo ""
echo "--- Test 3: non-superuser COPY (query) TO STDOUT is blocked ---"
out=$(PGPASSWORD=testpass $RU -c "COPY (SELECT 1) TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY TO command is not allowed"; then
    pass "non-superuser COPY (query) TO STDOUT blocked"
else
    fail "non-superuser COPY (query) TO STDOUT not blocked; got: $out"
fi

echo ""
echo "=== Superuser bypass ==="

echo ""
echo "--- Test 4: superuser COPY TO STDOUT is allowed ---"
out=$($SU -c "COPY (SELECT 1) TO STDOUT;" 2>&1)
if echo "$out" | grep -q "^1$"; then
    pass "superuser COPY TO STDOUT allowed"
else
    fail "superuser COPY TO STDOUT not allowed; got: $out"
fi

echo ""
echo "=== GUC block_copy_command.enabled ==="

echo ""
echo "--- Test 5: disable GUC -> non-superuser COPY is allowed ---"
psql -c "ALTER ROLE testuser SET block_copy_command.enabled = off;"
out=$(PGPASSWORD=testpass $RU -c "COPY (SELECT 1) TO STDOUT;" 2>&1)
if echo "$out" | grep -q "^1$"; then
    pass "non-superuser COPY allowed when GUC disabled"
else
    fail "non-superuser COPY not allowed when GUC disabled; got: $out"
fi

echo ""
echo "--- Test 6: re-enable GUC -> non-superuser COPY is blocked again ---"
psql -c "ALTER ROLE testuser RESET block_copy_command.enabled;"
out=$(PGPASSWORD=testpass $RU -c "COPY (SELECT 1) TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY TO command is not allowed"; then
    pass "non-superuser COPY blocked after GUC re-enabled"
else
    fail "non-superuser COPY not blocked after GUC re-enabled; got: $out"
fi

echo ""
echo "=== GUC block_copy_command.blocked_roles ==="

echo ""
echo "--- Test 7: superuser in blocked_roles is blocked ---"
out=$(psql -c "SET block_copy_command.blocked_roles = 'postgres'; COPY (SELECT 1) TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY TO command is not allowed"; then
    pass "superuser blocked when listed in blocked_roles"
else
    fail "superuser not blocked when listed in blocked_roles; got: $out"
fi

echo ""
echo "--- Test 8: superuser not in blocked_roles is still allowed ---"
out=$(psql -c "SET block_copy_command.blocked_roles = 'someother'; COPY (SELECT 1) TO STDOUT;" 2>&1)
if echo "$out" | grep -q "^1$"; then
    pass "superuser allowed when not listed in blocked_roles"
else
    fail "superuser not allowed when not listed in blocked_roles; got: $out"
fi

echo ""
echo "--- Test 9: non-superuser in blocked_roles is blocked even when enabled=off ---"
psql -c "ALTER ROLE testuser SET block_copy_command.enabled = off;"
psql -c "ALTER ROLE testuser SET block_copy_command.blocked_roles = 'testuser';"
out=$(PGPASSWORD=testpass $RU -c "COPY (SELECT 1) TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY TO command is not allowed"; then
    pass "non-superuser in blocked_roles is blocked even when enabled=off"
else
    fail "non-superuser in blocked_roles not blocked when enabled=off; got: $out"
fi
psql -c "ALTER ROLE testuser RESET block_copy_command.enabled;"
psql -c "ALTER ROLE testuser RESET block_copy_command.blocked_roles;"

echo ""
echo "=== GUC block_copy_command.block_from ==="

echo ""
echo "--- Test 10: block_from=off -> COPY FROM allowed, COPY TO still blocked ---"
psql -c "ALTER ROLE testuser SET block_copy_command.block_from = off;"
out=$(PGPASSWORD=testpass $RU -c "COPY (SELECT 1) TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY TO command is not allowed"; then
    pass "COPY TO still blocked when block_from=off"
else
    fail "COPY TO not blocked when block_from=off; got: $out"
fi
psql -c "CREATE TABLE IF NOT EXISTS _bcc_from_test (id int);"
psql -c "GRANT INSERT ON _bcc_from_test TO testuser;"
out=$(PGPASSWORD=testpass $RU -c "COPY _bcc_from_test FROM STDIN;" 2>&1)
if ! echo "$out" | grep -q "not allowed"; then
    pass "COPY FROM allowed when block_from=off"
else
    fail "COPY FROM blocked when block_from=off; got: $out"
fi
psql -c "DROP TABLE _bcc_from_test;"
psql -c "ALTER ROLE testuser RESET block_copy_command.block_from;"

echo ""
echo "--- Test 11: block_to=off -> COPY TO allowed, COPY FROM still blocked ---"
psql -c "ALTER ROLE testuser SET block_copy_command.block_to = off;"
psql -c "GRANT SELECT ON pg_class TO testuser;"
out=$(PGPASSWORD=testpass $RU -c "COPY (SELECT 1) TO STDOUT;" 2>&1)
if ! echo "$out" | grep -q "not allowed"; then
    pass "COPY TO allowed when block_to=off"
else
    fail "COPY TO blocked when block_to=off; got: $out"
fi
out=$(PGPASSWORD=testpass $RU -c "COPY pg_class FROM STDIN;" 2>&1 || true)
if echo "$out" | grep -q "COPY FROM command is not allowed"; then
    pass "COPY FROM still blocked when block_to=off"
else
    fail "COPY FROM not blocked when block_to=off; got: $out"
fi
psql -c "ALTER ROLE testuser RESET block_copy_command.block_to;"

echo ""
echo "=== GUC block_copy_command.block_program ==="

echo ""
echo "--- Test 12: COPY TO PROGRAM blocked for superuser by default ---"
out=$(psql -c "COPY (SELECT 1) TO PROGRAM 'cat';" 2>&1 || true)
if echo "$out" | grep -q "COPY TO PROGRAM command is not allowed"; then
    pass "COPY TO PROGRAM blocked for superuser (block_program=on)"
else
    fail "COPY TO PROGRAM not blocked for superuser; got: $out"
fi

echo ""
echo "--- Test 13: block_program=off -> COPY TO PROGRAM allowed for superuser ---"
out=$(psql -c "SET block_copy_command.block_program = off; COPY (SELECT 1) TO PROGRAM 'cat';" 2>&1)
if ! echo "$out" | grep -q "not allowed"; then
    pass "COPY TO PROGRAM allowed for superuser when block_program=off"
else
    fail "COPY TO PROGRAM blocked for superuser when block_program=off; got: $out"
fi

echo ""
echo "=== Regular SQL unaffected ==="

echo ""
echo "--- Test 14: SELECT works ---"
result=$(psql -t -A -c "SELECT 42;")
if [ "$result" = "42" ]; then
    pass "Regular SELECT works"
else
    fail "Expected '42', got: '$result'"
fi

echo ""
echo "--- Test 15: DDL and DML work ---"
count=$(psql -t -A <<'SQL' | tail -1
CREATE TEMP TABLE _docker_test (id int);
INSERT INTO _docker_test VALUES (1), (2), (3);
SELECT count(*) FROM _docker_test;
SQL
)
if [ "$count" = "3" ]; then
    pass "CREATE TABLE / INSERT / SELECT work"
else
    fail "Expected count 3, got: '$count'"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ]
