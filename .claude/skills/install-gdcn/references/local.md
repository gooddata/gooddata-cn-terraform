# Local (k3d) reference for install-gdcn

Terraform creates a k3d cluster in Docker (one server, two agents), an
in-cluster PostgreSQL (CloudNativePG), SeaweedFS as S3-compatible storage, and
the GoodData.CN release. Every value below lives in `local/settings.tfvars`; the
validations quoted here are the ones in `local/variables.tf`.

## Extra prerequisites

```bash
docker info >/dev/null && echo "docker ok"
k3d version
```

Ports 80 and 443 on the Docker host must be free: k3d binds them on its load
balancer container. Inside a Dev Container the check has to run on the host,
not in the container.

## Required values

The example is complete for a first install. Only two values ever change:

| Variable | What to ask |
| --- | --- |
| `gdcn_license_key` | The user pastes it into the file. |
| `k3d_kubeapi_host` | See the rule below. |

`size_profile` accepts only `dev` and `tls_mode` only `selfsigned`; do not offer
other values. `auth_hostname` (`auth.localhost`) and the organization hostname
(`gooddata.localhost`) resolve to loopback without any hosts file entry.

## The k3d_kubeapi_host rule

The generated kubeconfig points at `k3d_kubeapi_host`, default
`host.docker.internal`. That name resolves inside Docker Desktop and inside a
Dev Container, but not on a plain Linux host. Decide before the first apply:

```bash
getent hosts host.docker.internal
```

- Prints an address: keep the default.
- Prints nothing and Terraform runs directly on a Linux host: uncomment
  `k3d_kubeapi_host = "127.0.0.1"` in `settings.tfvars`.

Skipping this shows up after phase one as a Kubernetes provider error such as
"dial tcp: lookup host.docker.internal: no such host" or "connection refused".

## Apply: two phases

Phase one creates only the cluster, because the Kubernetes and Helm providers
try to connect during plan and there is nothing to connect to yet:

```bash
terraform plan -target=null_resource.k3d_cluster -var-file=settings.tfvars -out=tfplan
terraform apply tfplan && rm tfplan
```

Terraform warns that a targeted plan is incomplete; that is expected here.
Phase two is the normal plan and apply from the main skill. Each phase gets its
own confirmation.

Skipping phase one on a fresh machine fails with a provider connection error,
not a helpful message. If the user already has a cluster named
`k3d_cluster_name`, phase one detects it and does not recreate it.

## Verify

```bash
terraform output kubeconfig_context
terraform output hosts_file_entries
kubectl get pods -n gooddata-cn --field-selector=status.phase!=Running,status.phase!=Succeeded
```

`hosts_file_entries` only matters when the user changed a hostname away from
`*.localhost`. The HTTPS check depends on where the command runs:

```bash
# on the Docker host
curl -kIs https://gooddata.localhost
# inside a Dev Container, where localhost is the container itself
curl -kIs --connect-to gooddata.localhost:443:host.docker.internal:443 https://gooddata.localhost
```

Expect 200 or a redirect to `auth.localhost`. The certificate is self-signed, so
`-k` is required and the browser warns on first open.

## Teardown notes for the report

`terraform destroy -var-file=settings.tfvars` deletes the k3d cluster. If the
state is lost, `k3d cluster delete <k3d_cluster_name>` removes the containers
and their volumes.
