-- Creates a login role if it is missing. Variables: role.
-- The password is set afterwards with psql \password, which sends only the
-- SCRAM verifier, so the plaintext never reaches the server or its log.
select format('create role %I with login', :'role')
  where not exists (select 1 from pg_roles where rolname = :'role')
\gexec

alter role :"role" with login;
