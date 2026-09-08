###
# Per-service Postgres roles, so a compromised application container reaches
# one database instead of all of them. var.db_username stays the privileged
# bootstrap identity, used only by the chart's check-postgres-db init
# containers and by the Job below - never by an application process.
###

locals {
  # Defaults are merged in below, so each entry states only what is unusual.
  # role: Postgres role name. secret/key: where its password lives.
  # database: the database it owns, "" for roles the chart keeps runtime-only.
  # job: which bootstrap Job, and so which namespace, provisions it.
  pg_user_defaults = {
    key           = "postgresql-password"
    database      = ""
    revoke_public = false
    job           = "gdcn"
    enabled       = true
  }

  pg_users = { for name, user in {
    metadata_api = { role = "gdcn_md", secret = "gdcn-db-metadata-api", database = "md" }
    # Chart-fixed role name, and the Secret key is fixed too.
    md_exporter = { role = "md_exporter", secret = "gdcn-db-md-exporter", key = "exporter-password" }
    automation  = { role = "gdcn_automation", secret = "gdcn-db-automation", database = "automation" }
    dex         = { role = "gdcn_dex", secret = "gdcn-db-dex", database = "dex" }
    # The two gw runtime roles stay CONNECT-only; the owner holds the DDL.
    gateway_forge       = { role = "gdcn_gw", secret = "gdcn-db-gateway-forge" }
    gateway_forge_owner = { role = "gdcn_gw_owner", secret = "gdcn-db-gateway-forge-owner", database = "gw" }
    api_gw              = { role = "gdcn_api_gw", secret = "gdcn-db-api-gw" }
    gen_ai              = { role = "gdcn_genai", secret = "gdcn-db-gen-ai", database = "genai", enabled = var.enable_ai_features }
    ai_lake             = { role = "gdcn_ailake", secret = "gdcn-db-ai-lake", database = "ailake", enabled = var.cloud == "aws" && var.enable_ai_lake }
    # Its password rides in the Secret the Langfuse chart already reads, and
    # nothing else connects to this database, so PUBLIC loses access.
    langfuse = {
      role          = "langfuse"
      secret        = local.langfuse_secret_name
      key           = "postgres_password"
      database      = local.langfuse_postgres_database
      revoke_public = true
      job           = "langfuse"
      enabled       = var.enable_llm_observability
    }
    } : name => merge(local.pg_user_defaults, user)
  }

  pg_users_enabled = { for name, user in local.pg_users : name => user if user.enabled }

  # One Job per namespace that needs one. Namespace names are literals, so this
  # stays readable while the langfuse feature flag is off.
  pg_bootstrap_jobs = {
    gdcn = {
      namespace    = var.gdcn_namespace
      admin_secret = "gdcn-db-admin"
      enabled      = true
    }
    langfuse = {
      namespace    = local.langfuse_namespace
      admin_secret = "postgres-admin"
      enabled      = var.enable_llm_observability
    }
  }

  pg_bootstrap_jobs_enabled = { for job, cfg in local.pg_bootstrap_jobs : job => cfg if cfg.enabled }

  pg_users_by_job = {
    for job in keys(local.pg_bootstrap_jobs) :
    job => { for name, user in local.pg_users_enabled : name => user if user.job == job }
  }

  pg_password_key = local.pg_user_defaults.key
  pg_client_image = "${var.registry_dockerio}/library/postgres:16-alpine"

  langfuse_postgres_username = local.pg_users.langfuse.role
  langfuse_postgres_password = one([for name, pw in random_password.gdcn_db_user : pw.result if name == "langfuse"])
}

# Passwords ride inside connection strings, so they stay alphanumeric.
resource "random_password" "gdcn_db_user" {
  for_each = local.pg_users_enabled

  length  = 32
  special = false
}

# Pre-created rather than passed as database.password, which would put every
# password in plaintext into the rendered values and the Helm release secret.
# Langfuse is absent because its password rides in langfuse-server-secrets.
resource "kubernetes_secret_v1" "gdcn_db_user" {
  for_each = local.pg_users_by_job["gdcn"]

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

# The bootstrap credential. The GDCN copy is referenced as
# service.postgres.existingSecret, so its password no longer appears in the
# rendered values; the langfuse copy is read only by the Job.
resource "kubernetes_secret_v1" "gdcn_db_admin" {
  for_each = local.pg_bootstrap_jobs_enabled

  metadata {
    name      = each.value.admin_secret
    namespace = each.value.namespace
  }

  data = {
    (local.pg_password_key) = var.db_password
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
    kubernetes_namespace_v1.langfuse,
  ]
}

locals {
  # metadataApi pulls a second role's Secret, dex nests under .config and has no
  # existingSecretKey, and gatewayForge carries the owner alongside its runtime
  # role - the rest are the same two keys under a camelCase chart name.
  pg_uniform_value_keys = {
    automation = "automation"
    api_gw     = "apiGw"
    gen_ai     = "genAi"
    ai_lake    = "aiLake"
  }

  gdcn_db_user_values = merge(
    {
      for name, chart_key in local.pg_uniform_value_keys : chart_key => {
        database = {
          user           = local.pg_users[name].role
          existingSecret = local.pg_users[name].secret
        }
      } if local.pg_users[name].enabled
    },
    {
      metadataApi = {
        database = {
          user                   = local.pg_users.metadata_api.role
          existingSecret         = local.pg_users.metadata_api.secret
          existingExporterSecret = local.pg_users.md_exporter.secret
        }
      }
      dex = {
        config = {
          database = {
            user           = local.pg_users.dex.role
            existingSecret = local.pg_users.dex.secret
          }
        }
      }
      # gateway-forge's init container creates the api-gw role too, so the two
      # are configured together. Both stay CONNECT-only; Liquibase runs as the
      # owner, which is a one-way ownership migration of the gw database.
      gatewayForge = {
        database = {
          user                  = local.pg_users.gateway_forge.role
          existingSecret        = local.pg_users.gateway_forge.secret
          gwOwnerUser           = local.pg_users.gateway_forge_owner.role
          gwOwnerExistingSecret = local.pg_users.gateway_forge_owner.secret
        }
      }
    },
  )
}

locals {
  # The SQL lives in files/ so it can be read as SQL. Each script takes psql
  # variables, so nothing is templated and nothing is pasted into SQL text.
  pg_sql_scripts = {
    role     = file("${path.module}/files/postgres-role.sql")
    database = file("${path.module}/files/postgres-database.sql")
    chown    = file("${path.module}/files/postgres-chown.sql")
  }

  pg_role_lines = { for name, user in local.pg_users : name => compact(concat(
    ["$PSQL -v role=${user.role} -v pw=\"$PG_PW_${upper(name)}\" -f /tmp/sql/role.sql"],
    user.database == "" ? [] : [
      "$PSQL -v role=${user.role} -v db=${user.database} -f /tmp/sql/database.sql",
      user.revoke_public ? "$PSQL -c 'revoke all on database ${user.database} from public'" : "",
      "$PSQL -d ${user.database} -v role=${user.role} -f /tmp/sql/chown.sql",
    ],
  )) }

  pg_bootstrap_lines = { for job, users in local.pg_users_by_job : job => concat(
    [
      "PSQL='psql -v ON_ERROR_STOP=1'",
      "i=0; until pg_isready -q; do i=$((i+1)); [ $i -lt 30 ] || { echo 'Postgres unreachable'; exit 1; }; sleep 2; done",
      "mkdir -p /tmp/sql",
    ],
    flatten([for kind, sql in local.pg_sql_scripts : [
      "cat > /tmp/sql/${kind}.sql <<'PGSQL'",
      trimspace(sql),
      "PGSQL",
    ]]),
    flatten([for name in sort(keys(users)) : local.pg_role_lines[name]]),
  ) }

  # Job names are immutable, so this hash in the name is what re-runs a
  # bootstrap. It covers the credentials and the roles, not the script text;
  # bump the version when the SQL above changes behaviour.
  pg_bootstrap_version = "v1"

  pg_bootstrap_hash = { for job, users in local.pg_users_by_job : job => substr(sha256(jsonencode([
    local.pg_bootstrap_version,
    var.db_password,
    { for name, user in users : name => [
      user.role, user.database, user.revoke_public, random_password.gdcn_db_user[name].result
    ] },
  ])), 0, 8) }
}

resource "kubernetes_job_v1" "gdcn_db_bootstrap" {
  for_each = local.pg_bootstrap_jobs_enabled

  metadata {
    name      = "${each.key}-db-bootstrap-${local.pg_bootstrap_hash[each.key]}"
    namespace = each.value.namespace
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
          image = local.pg_client_image

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
                name = each.value.admin_secret
                key  = local.pg_password_key
              }
            }
          }

          dynamic "env" {
            for_each = local.pg_users_by_job[each.key]

            content {
              name = "PG_PW_${upper(env.key)}"
              value_from {
                secret_key_ref {
                  name = env.value.secret
                  key  = env.value.key
                }
              }
            }
          }

          command = ["/bin/sh", "-ec", join("\n", local.pg_bootstrap_lines[each.key])]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  # The Secrets are referenced by name, so these edges are not implicit.
  depends_on = [
    kubernetes_namespace_v1.gdcn,
    kubernetes_namespace_v1.langfuse,
    kubernetes_secret_v1.gdcn_db_admin,
    kubernetes_secret_v1.gdcn_db_user,
    kubernetes_secret_v1.langfuse_server_secrets,
  ]
}
