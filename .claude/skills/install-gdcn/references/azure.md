# Azure (AKS) reference for install-gdcn

Terraform creates a resource group, VNet, AKS cluster with node auto
provisioning, Azure Database for PostgreSQL, Blob storage, and the GoodData.CN
release. Every value below lives in `azure/settings.tfvars`; the validations
quoted here are the ones in `azure/variables.tf`.

## Extra prerequisites

- `az` CLI logged in to the right subscription.
- `kubelogin`: Terraform authenticates to AKS through it, so the apply fails
  without it even though `az` works.

## Required values

| Variable | What to ask |
| --- | --- |
| `azure_location` | Region for every resource. |
| `deployment_name` | Short name (18 alphanumerics at most after stripping); Azure appends a random suffix to some resources. |
| `size_profile` | One of `dev`, `prod-small`, `prod-large`. There is no `prod-xl` on Azure. Changing it after deploying is not a supported migration. |
| `dns_provider` | `self-managed` (default) or `azure-dns`. |
| `ingress_controller` and `tls_mode` | See the matrix below. |
| `auth_hostname`, `gdcn_orgs` | As in the main skill. |

`azure_subscription_id` and `azure_tenant_id` are optional: unset, Terraform uses
the current `az login` session. Set them only when the user works across
subscriptions.

## Ingress, TLS, and DNS matrix

| `ingress_controller` | `tls_mode` | Needs | Chart floor |
| --- | --- | --- | --- |
| `ingress-nginx` (default) | `letsencrypt` | `letsencrypt_email` set, public port 80 reachable for the ACME challenge. | none |
| `istio_gateway` | `letsencrypt` | `letsencrypt_email` set. Switching to or from Istio later needs a rollout restart of every workload. | `helm_gdcn_version` 3.53.0 or newer |

There is no ALB or ACM path on Azure.

With `dns_provider = "azure-dns"` the public DNS zone must exist before apply:

```bash
az network dns zone show --name <azure_dns_zone_name> --resource-group <azure_dns_zone_resource_group_name>
```

Terraform then deploys external-dns and maintains the records. The zone's name
servers are in the `azure_dns_zone_name_servers` output; the registrar must
point at them.

## Authenticate

The user runs `az login` in their terminal. Verify read-only:

```bash
az account show
kubelogin --version
```

## Apply

One phase. AKS and PostgreSQL take most of the time, then the Helm release with
its 3600 second wait.

## Verify

```bash
terraform output manual_dns_records
kubectl get svc -n ingress-nginx
```

- With `self-managed` DNS, `manual_dns_records` lists A records pointing at the
  load balancer IP; the user creates them. With `azure-dns` the list is empty
  because external-dns owns the records.
- There is no `tls_mode` output on Azure; read the value from the tfvars file
  when you need it.
- Let's Encrypt issuance needs the hostname to resolve publicly first. Check
  `kubectl get certificate -A`; a certificate that stays not Ready after DNS
  resolves is a `troubleshoot-gdcn` case.
- Then `curl -kIs https://<org_hostname>` should return 200 or a redirect to
  `auth_hostname`.

## Teardown notes for the report

`terraform destroy -var-file=settings.tfvars` removes the resource group and
everything in it. Backups configured with `postgresql_geo_redundant_backup` are
deleted with the server.
