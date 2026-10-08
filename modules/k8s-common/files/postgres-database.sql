-- Creates a database owned by the role, or takes over an existing one.
-- Variables: role, db.
--
-- The membership grant is what lets a managed-Postgres master, which is not a
-- superuser, reassign ownership to the role; the chart does the same for its
-- own obs_owner role. It is not revoked afterwards: Postgres 16 already grants
-- a new role to its creator with ADMIN OPTION, that grant is owned by the
-- bootstrap superuser rather than by us, and it carries NOINHERIT - so the
-- master gains no privileges from it and a revoke would only warn.
grant :"role" to current_user;

select format('create database %I owner %I', :'db', :'role')
  where not exists (select 1 from pg_database where datname = :'db')
\gexec

alter database :"db" owner to :"role";
