-- local-mcp Postgres bootstrap. Runs ONCE, only when the pg_data volume is
-- empty (Postgres docker-entrypoint-initdb.d convention). Creates the two
-- databases + roles + pgvector extension used by cognee and openmemory.
--
-- These passwords are LOCAL NON-SECRETS: the DB is bound to 127.0.0.1 inside
-- the Docker Desktop VM and is never network-exposed. They MUST match the
-- literals in cookbooks/local-mcp/files/generate_env.local.sh.
--
-- To change them later you must `docker volume rm local-mcp_pg_data` (DATA
-- LOSS) so this script re-runs, or apply the delta by hand — the entrypoint
-- does not re-run init scripts on a populated volume.

CREATE ROLE cognee WITH LOGIN PASSWORD 'cognee_local_dev';
CREATE ROLE mem0   WITH LOGIN PASSWORD 'mem0_local_dev';

CREATE DATABASE cognee OWNER cognee;
CREATE DATABASE mem0   OWNER mem0;

\connect cognee
CREATE EXTENSION IF NOT EXISTS vector;
GRANT ALL ON SCHEMA public TO cognee;

\connect mem0
CREATE EXTENSION IF NOT EXISTS vector;
GRANT ALL ON SCHEMA public TO mem0;
