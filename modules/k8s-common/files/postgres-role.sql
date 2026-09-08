-- Creates a login role if it is missing, then always syncs its password.
-- Variables: role, pw.
select format('create role %I with login', :'role')
  where not exists (select 1 from pg_roles where rolname = :'role')
\gexec

alter role :"role" with login password :'pw';
