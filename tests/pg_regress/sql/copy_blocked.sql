-- Test that COPY TO is blocked by the hook
CREATE TEMP TABLE copy_test (id int);
INSERT INTO copy_test VALUES (1), (2), (3);

\set ON_ERROR_STOP off

COPY copy_test TO STDOUT;

COPY copy_test FROM STDIN;
\.

COPY pg_class TO STDOUT;

\set ON_ERROR_STOP on

DROP TABLE copy_test;
