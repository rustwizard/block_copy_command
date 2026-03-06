#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Setting up extension ==="
psql -c "CREATE EXTENSION IF NOT EXISTS block_copy_command;"

echo ""
echo "=== Test 1: COPY TO STDOUT is blocked ==="
out=$(psql -c "COPY pg_class TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY command is not allowed"; then
    pass "COPY TO STDOUT blocked"
else
    fail "COPY TO STDOUT not blocked; got: $out"
fi

echo ""
echo "=== Test 2: COPY FROM STDIN is blocked ==="
out=$(psql -c "COPY pg_class FROM STDIN;" 2>&1 || true)
if echo "$out" | grep -q "COPY command is not allowed"; then
    pass "COPY FROM STDIN blocked"
else
    fail "COPY FROM STDIN not blocked; got: $out"
fi

echo ""
echo "=== Test 3: COPY (query) TO STDOUT is blocked ==="
out=$(psql -c "COPY (SELECT 1) TO STDOUT;" 2>&1 || true)
if echo "$out" | grep -q "COPY command is not allowed"; then
    pass "COPY (query) TO STDOUT blocked"
else
    fail "COPY (query) TO STDOUT not blocked; got: $out"
fi

echo ""
echo "=== Test 4: Regular SELECT works ==="
result=$(psql -t -A -c "SELECT 42;")
if [ "$result" = "42" ]; then
    pass "Regular SELECT works"
else
    fail "Expected '42', got: '$result'"
fi

echo ""
echo "=== Test 5: DDL and DML still work ==="
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
