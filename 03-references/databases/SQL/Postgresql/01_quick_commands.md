# PostgreSQL — SQL Quick Reference

---

## Connect via CLI

**Basic connection:**
```bash
psql -h <host> -p <port> -U <user> -d <database>
```

**Connect with password prompt:**
```bash
psql -h <host> -U <user> -W
```

**Connect via SSH tunnel (tunnel must be open first):**
```bash
psql -h 127.0.0.1 -p 5433 -U <user> -d <database>
```

**Connect using a connection string:**
```bash
psql "postgresql://<user>:<password>@<host>:<port>/<database>"
```

**Connect via SSL (recommended for RDS):**
```bash
psql "postgresql://<user>@<host>/<database>?sslmode=require"
```

**Run a single query without entering the shell:**
```bash
psql -h <host> -U <user> -d <database> -c "SELECT version();"
```

**Export a database dump:**
```bash
pg_dump -h <host> -U <user> -d <database> > dump.sql
```

**Export all databases:**
```bash
pg_dumpall -h <host> -U <user> > all_databases.sql
```

**Import a SQL file:**
```bash
psql -h <host> -U <user> -d <database> < dump.sql
```

**Useful psql meta-commands once inside the shell:**
```
\l              → list all databases
\c <database>   → connect to a database
\dt             → list tables
\d <table>      → describe a table
\du             → list users/roles
\q              → quit
```

---

## Users & Roles

**List all users:**
```sql
SELECT usename AS user, usesuper AS is_superuser, passwd AS password_status
FROM pg_shadow
ORDER BY usename;
```

**List all roles (users + groups):**
```sql
SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolcanlogin
FROM pg_roles
ORDER BY rolname;
```

**Check privileges for a specific user:**
```sql
\du <user>
-- or
SELECT * FROM information_schema.role_table_grants
WHERE grantee = '<user>';
```

**Find superusers:**
```sql
SELECT rolname FROM pg_roles WHERE rolsuper = true;
```

---

## Databases & Tables

**List all databases:**
```sql
\l
-- or
SELECT datname AS database FROM pg_database WHERE datistemplate = false;
```

**Connect to a database:**
```sql
\c <database>
```

**List all tables in current database:**
```sql
\dt
-- or
SELECT tablename FROM pg_tables WHERE schemaname = 'public';
```

**List all tables across all schemas:**
```sql
SELECT table_schema AS schema, table_name AS table
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY table_schema, table_name;
```

**Count tables per schema:**
```sql
SELECT table_schema AS schema, COUNT(*) AS total_tables
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND table_schema NOT IN ('pg_catalog', 'information_schema')
GROUP BY table_schema
ORDER BY table_schema;
```

**Get table sizes (largest first):**
```sql
SELECT
    schemaname AS schema,
    tablename AS table,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC;
```

**Describe a table's structure:**
```sql
\d <table>
-- or
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = '<table>'
ORDER BY ordinal_position;
```

**Show indexes on a table:**
```sql
\di <table>
-- or
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = '<table>';
```

---

## User Management

**Create a user:**
```sql
CREATE USER <user> WITH PASSWORD '<password>';
```

**Create a role (group):**
```sql
CREATE ROLE <role_name>;
```

**Grant read-only on all tables in a schema:**
```sql
GRANT SELECT ON ALL TABLES IN SCHEMA public TO <user>;
```

**Grant read-only on a specific table:**
```sql
GRANT SELECT ON <table> TO <user>;
```

**Grant write on a specific table:**
```sql
GRANT INSERT, UPDATE, DELETE ON <table> TO <user>;
```

**Grant full access on a database:**
```sql
GRANT ALL PRIVILEGES ON DATABASE <database> TO <user>;
```

**Revoke a privilege:**
```sql
REVOKE INSERT, UPDATE, DELETE ON <table> FROM <user>;
```

**Change a user's password:**
```sql
ALTER USER <user> WITH PASSWORD '<new_password>';
```

**Delete a user:**
```sql
DROP USER <user>;
```

---

## Performance

**Show currently running queries:**
```sql
SELECT pid, usename, state, query, query_start
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY query_start;
```

**Kill a running query:**
```sql
SELECT pg_cancel_backend(<pid>);
-- Force kill (if cancel doesn't work)
SELECT pg_terminate_backend(<pid>);
```

**EXPLAIN a slow query:**
```sql
EXPLAIN ANALYZE SELECT * FROM <table> WHERE <column> = '<value>';
```

**Check table statistics (dead rows, last vacuum):**
```sql
SELECT relname AS table, n_live_tup AS live_rows, n_dead_tup AS dead_rows,
       last_vacuum, last_autovacuum, last_analyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

**Enable slow query logging (postgresql.conf):**
```
log_min_duration_statement = 5000   -- log queries >5 seconds
log_statement = 'all'
```

---

*EXPLAIN red flags: `Seq Scan` = full table scan | `Hash Join` on large tables = missing index | high `rows=` estimate = stale stats, run `ANALYZE <table>`*