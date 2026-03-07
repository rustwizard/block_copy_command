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
psql -c "DROP ROLE IF EXISTS testuser;"
psql -c "CREATE ROLE testuser LOGIN PASSWORD 'testpass';"
psql -c "GRANT CONNECT ON DATABASE testdb TO testuser;"
export PGPASSWORD=postgres

echo ""
echo "=== Block for non-superuser (GUC enabled, default) ==="

echo ""
echo "--- Test 1: non-superuser COPY TO STDOUT is blocked ---"
out=$(PGPASSWORD=testpass $RU -c "COPY pg_class TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY command is not allowed"; then
    pass "non-superuser COPY TO STDOUT blocked"
else
    fail "non-superuser COPY TO STDOUT not blocked; got: $out"
fi

echo ""
echo "--- Test 2: non-superuser COPY FROM STDIN is blocked ---"
out=$(PGPASSWORD=testpass $RU -c "COPY pg_class FROM STDIN;" 2>&1 || true)
if echo "$out" | grep -q "COPY command is not allowed"; then
    pass "non-superuser COPY FROM STDIN blocked"
else
    fail "non-superuser COPY FROM STDIN not blocked; got: $out"
fi

echo ""
echo "--- Test 3: non-superuser COPY (query) TO STDOUT is blocked ---"
out=$(PGPASSWORD=testpass $RU -c "COPY (SELECT 1) TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY command is not allowed"; then
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
if echo "$out" | grep -q "COPY command is not allowed"; then
    pass "non-superuser COPY blocked after GUC re-enabled"
else
    fail "non-superuser COPY not blocked after GUC re-enabled; got: $out"
fi

echo ""
echo "=== Regular SQL unaffected ==="

echo ""
echo "--- Test 7: SELECT works ---"
result=$(psql -t -A -c "SELECT 42;")
if [ "$result" = "42" ]; then
    pass "Regular SELECT works"
else
    fail "Expected '42', got: '$result'"
fi

echo ""
echo "--- Test 8: DDL and DML work ---"
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
