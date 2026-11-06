-- Creates a login role if it is missing, then always syncs its password.
-- Variables: role, pw.
select format('create role %I with login', :'role')
  where not exists (select 1 from pg_roles where rolname = :'role')
\gexec

-- The password is in the statement text. Turn off statement logging for this
-- transaction so that log_statement = ddl or all does not write it to the
-- server log. Only a superuser can change log_statement (local CNPG); on RDS
-- and Azure the master is not a superuser, so the select does nothing there.
begin;
select set_config('log_statement', 'none', true)
  where (select rolsuper from pg_roles where rolname = current_user);
alter role :"role" with login password :'pw';
commit;
