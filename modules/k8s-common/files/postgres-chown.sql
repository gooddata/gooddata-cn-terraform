-- Hands every object in the current database over to the role, so the service
-- that connects as it can run its own migrations. Variable: role.
--
-- Why this exists: the chart transfers ownership itself, but only while the
-- role does not yet exist - every caller but gateway-forge guards its chownDb
-- routine with a pg_roles check. Once Terraform owns the role the chart never
-- does this, so it has to happen here.
--
-- Three statements cover everything: ALTER TABLE also owns views, materialized
-- views and sequences, and ALTER ROUTINE covers both functions and procedures.
-- Two exclusions matter:
--   deptype 'a'/'i' - sequences owned by a table column, which Postgres
--     refuses to reassign on their own; they follow their table.
--   deptype 'e'     - objects belonging to an extension, which stay with it.
-- The owner comparisons make a re-run emit nothing at all.

select format('alter schema %I owner to %I', nspname, :'role')
  from pg_namespace
  where nspname <> 'information_schema'
    and nspname !~ '^pg_'
    and nspowner <> :'role'::regrole

union all

select format('alter table %I.%I owner to %I', n.nspname, c.relname, :'role')
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p', 'v', 'm', 'S')
    and n.nspname <> 'information_schema'
    and n.nspname !~ '^pg_'
    and c.relowner <> :'role'::regrole
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_class'::regclass
        and d.objid = c.oid
        and d.deptype in ('a', 'e', 'i')
    )

union all

select format('alter routine %I.%I(%s) owner to %I',
              n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), :'role')
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where p.prokind in ('f', 'p')
    and n.nspname <> 'information_schema'
    and n.nspname !~ '^pg_'
    and p.proowner <> :'role'::regrole
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_proc'::regclass
        and d.objid = p.oid
        and d.deptype = 'e'
    )
\gexec
