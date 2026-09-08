###
# Per-service Postgres roles, so a compromised application container reaches
# one database instead of all of them. var.db_username stays the privileged
# bootstrap identity: the chart's check-postgres-db init containers run as it to
# create each database, create each role and sync its password on every start.
###

locals {
  # role: Postgres role name. secret/key: where its password lives. database:
  # the database it owns, "" for roles the chart keeps as runtime-only. scope:
  # which bootstrap Job and namespace it belongs to.
  gdcn_db_users = {
    metadata_api = {
      role          = "gdcn_md"
      secret        = "gdcn-db-metadata-api"
      key           = "postgresql-password"
      database      = "md"
      revoke_public = false
      scope         = "gdcn"
      enabled       = true
    }
    # Chart-fixed role name; only the Secret is ours, and the key is fixed too.
    md_exporter = {
      role          = "md_exporter"
      secret        = "gdcn-db-md-exporter"
      key           = "exporter-password"
      database      = ""
      revoke_public = false
      scope         = "gdcn"
      enabled       = true
    }
    automation = {
      role          = "gdcn_automation"
      secret        = "gdcn-db-automation"
      key           = "postgresql-password"
      database      = "automation"
      revoke_public = false
      scope         = "gdcn"
      enabled       = true
    }
    dex = {
      role          = "gdcn_dex"
      secret        = "gdcn-db-dex"
      key           = "postgresql-password"
      database      = "dex"
      revoke_public = false
      scope         = "gdcn"
      enabled       = true
    }
    # The two gw runtime roles stay CONNECT-only; the owner below holds the DDL.
    gateway_forge = {
      role          = "gdcn_gw"
      secret        = "gdcn-db-gateway-forge"
      key           = "postgresql-password"
      database      = ""
      revoke_public = false
      scope         = "gdcn"
      enabled       = true
    }
    gateway_forge_owner = {
      role          = "gdcn_gw_owner"
      secret        = "gdcn-db-gateway-forge-owner"
      key           = "postgresql-password"
      database      = "gw"
      revoke_public = false
      scope         = "gdcn"
      enabled       = true
    }
    api_gw = {
      role          = "gdcn_api_gw"
      secret        = "gdcn-db-api-gw"
      key           = "postgresql-password"
      database      = ""
      revoke_public = false
      scope         = "gdcn"
      enabled       = true
    }
    gen_ai = {
      role          = "gdcn_genai"
      secret        = "gdcn-db-gen-ai"
      key           = "postgresql-password"
      database      = "genai"
      revoke_public = false
      scope         = "gdcn"
      enabled       = var.enable_ai_features
    }
    ai_lake = {
      role          = "gdcn_ailake"
      secret        = "gdcn-db-ai-lake"
      key           = "postgresql-password"
      database      = "ailake"
      revoke_public = false
      scope         = "gdcn"
      enabled       = var.cloud == "aws" && var.enable_ai_lake
    }
    # The chart's deploySpiceDB defaults to false and we never enable it.
    spicedb = {
      role          = "gdcn_spicedb"
      secret        = "gdcn-db-spicedb"
      key           = "postgresql-password"
      database      = "spicedb"
      revoke_public = false
      scope         = "gdcn"
      enabled       = false
    }
    # Its password rides in the Secret the Langfuse chart already reads, and
    # nothing but Langfuse connects to this database, so PUBLIC loses access.
    langfuse = {
      role          = "langfuse"
      secret        = local.langfuse_secret_name
      key           = "postgres_password"
      database      = "langfuse"
      revoke_public = true
      scope         = "langfuse"
      enabled       = var.enable_llm_observability
    }
  }

  gdcn_db_users_enabled = { for name, user in local.gdcn_db_users : name => user if user.enabled && user.scope == "gdcn" }

  # Langfuse is the only Postgres consumer whose role Terraform has to create
  # itself; its chart cannot CREATE DATABASE as an unprivileged role.
  langfuse_postgres_username = local.gdcn_db_users.langfuse.role
  langfuse_postgres_password = join("", random_password.langfuse_postgres[*].result)

  gdcn_db_admin_secret_name     = "gdcn-db-admin"
  langfuse_db_admin_secret_name = "postgres-admin"
  gdcn_db_password_key          = "postgresql-password"
}

# Passwords ride inside connection strings, so they stay alphanumeric.
resource "random_password" "gdcn_db_user" {
  for_each = local.gdcn_db_users_enabled

  length  = 32
  special = false
}

# Pre-created rather than passed as database.password, which would put every
# password in plaintext into the rendered values and the Helm release secret.
resource "kubernetes_secret_v1" "gdcn_db_user" {
  for_each = local.gdcn_db_users_enabled

  metadata {
    name      = each.value.secret
    namespace = var.gdcn_namespace
  }

  data = {
    (each.value.key) = random_password.gdcn_db_user[each.key].result
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}

# The bootstrap credential, referenced as service.postgres.existingSecret so it
# no longer appears in the values file.
resource "kubernetes_secret_v1" "gdcn_db_admin" {
  metadata {
    name      = local.gdcn_db_admin_secret_name
    namespace = var.gdcn_namespace
  }

  data = {
    (local.gdcn_db_password_key) = var.db_password
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}

locals {
  # dex nests its block under .config and has no existingSecretKey - the chart
  # hardcodes "postgresql-password" there.
  gdcn_db_user_values = merge(
    {
      metadataApi = {
        database = {
          user                   = local.gdcn_db_users.metadata_api.role
          existingSecret         = local.gdcn_db_users.metadata_api.secret
          existingExporterSecret = local.gdcn_db_users.md_exporter.secret
        }
      }
      automation = {
        database = {
          user           = local.gdcn_db_users.automation.role
          existingSecret = local.gdcn_db_users.automation.secret
        }
      }
      dex = {
        config = {
          database = {
            user           = local.gdcn_db_users.dex.role
            existingSecret = local.gdcn_db_users.dex.secret
          }
        }
      }
      # gateway-forge's init container creates the api-gw role too, so the two
      # are configured together. Both stay CONNECT-only; Liquibase runs as the
      # owner, which is a one-way ownership migration of the gw database.
      gatewayForge = {
        database = {
          user                  = local.gdcn_db_users.gateway_forge.role
          existingSecret        = local.gdcn_db_users.gateway_forge.secret
          gwOwnerUser           = local.gdcn_db_users.gateway_forge_owner.role
          gwOwnerExistingSecret = local.gdcn_db_users.gateway_forge_owner.secret
        }
      }
      apiGw = {
        database = {
          user           = local.gdcn_db_users.api_gw.role
          existingSecret = local.gdcn_db_users.api_gw.secret
        }
      }
    },
    local.gdcn_db_users.gen_ai.enabled ? {
      genAi = {
        database = {
          user           = local.gdcn_db_users.gen_ai.role
          existingSecret = local.gdcn_db_users.gen_ai.secret
        }
      }
    } : {},
    local.gdcn_db_users.ai_lake.enabled ? {
      aiLake = {
        database = {
          user           = local.gdcn_db_users.ai_lake.role
          existingSecret = local.gdcn_db_users.ai_lake.secret
        }
      }
    } : {},
  )
}

# --------------------------------------------------------------------------
# Langfuse role and database
# --------------------------------------------------------------------------

resource "random_password" "langfuse_postgres" {
  count = var.enable_llm_observability ? 1 : 0

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "langfuse_db_admin" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = local.langfuse_db_admin_secret_name
    namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
  }

  data = {
    (local.gdcn_db_password_key) = var.db_password
  }
}

locals {
  # ROLE_NAME is substituted per role. The chart runs the same transfer on every
  # pod start but enumerates sequences linked to a table column, which Postgres
  # refuses to reassign on their own - it aborts the transaction that also
  # creates the role, so the pod then cannot authenticate. Running it here first,
  # tables before sequences and linked sequences left to follow their table,
  # makes the chart's own pass a no-op that commits.
  pg_chown_sql_template = <<-SQL
    do $chown$
    declare
      sql_stmt text;
    begin
      for sql_stmt in
        select stmt from (
          select 1 as ord, format('alter schema %I owner to %I', nspname, 'ROLE_NAME') as stmt
            from pg_namespace
            where nspname <> 'information_schema' and nspname !~ '^pg_'
          union all
          select
            case when c.relkind = 'S' then 3 else 2 end,
            format('alter %s %I.%I owner to %I',
              case c.relkind
                when 'v' then 'view'
                when 'm' then 'materialized view'
                when 'S' then 'sequence'
                else 'table'
              end,
              n.nspname, c.relname, 'ROLE_NAME')
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where c.relkind in ('r', 'p', 'v', 'm', 'S')
              and n.nspname <> 'information_schema' and n.nspname !~ '^pg_'
              and not exists (
                select 1 from pg_depend d
                where d.classid = 'pg_class'::regclass and d.objid = c.oid
                  and d.deptype in ('a', 'e', 'i')
              )
          union all
          select 4, format('alter %s %I.%I(%s) owner to %I',
              case when p.prokind = 'p' then 'procedure' else 'function' end,
              n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), 'ROLE_NAME')
            from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
            where p.prokind in ('f', 'p')
              and n.nspname <> 'information_schema' and n.nspname !~ '^pg_'
              and not exists (
                select 1 from pg_depend d
                where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
              )
          order by ord
        ) x
      loop
        execute sql_stmt;
      end loop;
    end
    $chown$;
  SQL

  # Create-then-always-alter, the same shape the chart uses for its own roles.
  # Passwords are alphanumeric, so single quoting them is safe. The temporary
  # role membership is what lets a managed-Postgres master (not a real
  # superuser) hand a database over; the chart does the same for obs_owner.
  pg_role_lines = {
    for name, user in local.gdcn_db_users : name => concat(
      [
        "echo '--- ${user.role} ---'",
        "if [ \"$(psql -Atqc \"select 1 from pg_roles where rolname = '${user.role}'\")\" != \"1\" ]; then",
        "  psql -v ON_ERROR_STOP=1 -c \"create role ${user.role} with login password '$PG_PW_${upper(name)}'\"",
        "fi",
        "psql -v ON_ERROR_STOP=1 -c \"alter role ${user.role} with login password '$PG_PW_${upper(name)}'\"",
      ],
      user.database == "" ? [] : [
        "psql -v ON_ERROR_STOP=1 -c 'grant ${user.role} to current_user'",
        "if [ \"$(psql -Atqc \"select 1 from pg_database where datname = '${user.database}'\")\" != \"1\" ]; then",
        "  createdb -O ${user.role} ${user.database}",
        "fi",
        "psql -v ON_ERROR_STOP=1 -c 'alter database ${user.database} owner to ${user.role}'",
        "psql -v ON_ERROR_STOP=1 -d ${user.database} <<'EOSQL_${upper(name)}'",
        trimspace(replace(local.pg_chown_sql_template, "ROLE_NAME", user.role)),
        "EOSQL_${upper(name)}",
      ],
      user.revoke_public ? [
        "psql -v ON_ERROR_STOP=1 -c 'revoke all on database ${user.database} from public'",
      ] : [],
      user.database == "" ? [] : [
        "psql -v ON_ERROR_STOP=1 -c 'revoke ${user.role} from current_user'",
      ],
    )
  }

  pg_wait_lines = [
    "echo 'Waiting for Postgres...'",
    "max=60; i=1",
    "while [ $i -le $max ]; do",
    "  if pg_isready -q; then break; fi",
    "  sleep 5; i=$((i+1))",
    "done",
    "if [ $i -gt $max ]; then echo 'Postgres did not become ready in time'; exit 1; fi",
  ]

  gdcn_db_bootstrap_lines = concat(local.pg_wait_lines, flatten([
    for name in sort(keys(local.gdcn_db_users_enabled)) : local.pg_role_lines[name]
  ]))

  langfuse_db_bootstrap_lines = concat(local.pg_wait_lines, local.pg_role_lines["langfuse"])

  # Job names are immutable, so these hashes in the names are what re-run a
  # bootstrap when a password or the SQL changes.
  gdcn_db_bootstrap_hash = substr(sha256("${join(",", [
    for name in sort(keys(local.gdcn_db_users_enabled)) : random_password.gdcn_db_user[name].result
  ])}${join("\n", local.gdcn_db_bootstrap_lines)}"), 0, 8)

  langfuse_db_bootstrap_hash = substr(sha256("${local.langfuse_postgres_password}${join("\n", local.langfuse_db_bootstrap_lines)}"), 0, 8)
}

resource "kubernetes_job_v1" "gdcn_db_bootstrap" {
  metadata {
    name      = "gdcn-db-bootstrap-${local.gdcn_db_bootstrap_hash}"
    namespace = var.gdcn_namespace
  }

  spec {
    backoff_limit = 4

    template {
      metadata {
        # A sidecar never exits, so the Job would never complete; Postgres'
        # wire protocol is not proxyable by Envoy anyway.
        annotations = {
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "bootstrap"
          image = "${var.registry_dockerio}/library/postgres:16-alpine"

          env {
            name  = "PGHOST"
            value = var.db_hostname
          }
          env {
            name  = "PGUSER"
            value = var.db_username
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }
          env {
            name  = "PGSSLMODE"
            value = "require"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.gdcn_db_admin.metadata[0].name
                key  = local.gdcn_db_password_key
              }
            }
          }

          dynamic "env" {
            for_each = local.gdcn_db_users_enabled

            content {
              name = "PG_PW_${upper(env.key)}"
              value_from {
                secret_key_ref {
                  name = kubernetes_secret_v1.gdcn_db_user[env.key].metadata[0].name
                  key  = env.value.key
                }
              }
            }
          }

          command = ["/bin/sh", "-ec", join("\n", local.gdcn_db_bootstrap_lines)]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
    kubernetes_secret_v1.gdcn_db_admin,
    kubernetes_secret_v1.gdcn_db_user,
  ]
}

resource "kubernetes_job_v1" "langfuse_db_bootstrap" {
  count = var.enable_llm_observability ? 1 : 0

  metadata {
    name      = "langfuse-db-bootstrap-${local.langfuse_db_bootstrap_hash}"
    namespace = kubernetes_namespace_v1.langfuse[0].metadata[0].name
  }

  spec {
    backoff_limit = 4

    template {
      metadata {
        # A sidecar never exits, so the Job would never complete; Postgres'
        # wire protocol is not proxyable by Envoy anyway.
        annotations = {
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "bootstrap"
          image = "${var.registry_dockerio}/library/postgres:16-alpine"

          env {
            name  = "PGHOST"
            value = var.db_hostname
          }
          env {
            name  = "PGUSER"
            value = var.db_username
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }
          env {
            name  = "PGSSLMODE"
            value = "require"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.langfuse_db_admin[0].metadata[0].name
                key  = local.gdcn_db_password_key
              }
            }
          }
          env {
            name = "PG_PW_LANGFUSE"
            value_from {
              secret_key_ref {
                name = local.gdcn_db_users.langfuse.secret
                key  = local.gdcn_db_users.langfuse.key
              }
            }
          }

          command = ["/bin/sh", "-ec", join("\n", local.langfuse_db_bootstrap_lines)]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_secret_v1.langfuse_server_secrets,
    kubernetes_secret_v1.langfuse_db_admin,
  ]
}
