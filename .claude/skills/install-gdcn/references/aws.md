# AWS (EKS) reference for install-gdcn

Terraform creates a VPC (or uses an existing one), an EKS cluster with Karpenter
for worker nodes, RDS PostgreSQL, S3 buckets, and the GoodData.CN release. Every
value below lives in `aws/settings.tfvars`; the validations quoted here are the
ones in `aws/variables.tf`.

## Extra prerequisites

- `aws` CLI, plus a profile in `~/.aws/config` that can create VPC, EKS, RDS,
  IAM, S3, ACM, and Route53 resources.
- Docker Hub credentials only when the user wants `enable_image_cache`.

## Required values

| Variable | What to ask |
| --- | --- |
| `aws_profile_name` | The profile name. Terraform uses this profile regardless of `AWS_PROFILE` or exported keys, because `aws/providers.tf` pins it. |
| `aws_region` | Region for every resource. |
| `deployment_name` | Lowercase DNS label; it prefixes cluster, database, and bucket names. |
| `size_profile` | One of `dev`, `prod-small`, `prod-large`, `prod-xl`. `dev` is the smallest and not HA. Changing it after deploying is not a supported migration. |
| `dns_provider` | `route53` (Terraform manages records in `route53_zone_id`) or `self-managed` (the user creates records from outputs). |
| `ingress_controller` and `tls_mode` | See the matrix below. |
| `auth_hostname`, `gdcn_orgs` | As in the main skill. Hostnames must sit in the zone the user controls. |

## Ingress, TLS, and DNS matrix

Terraform rejects combinations outside this table at plan time.

| `ingress_controller` | `tls_mode` | Needs | Chart floor |
| --- | --- | --- | --- |
| `alb` (default) | `acm` | TLS ends at the AWS ALB with an ACM certificate. With `self-managed` DNS the user must create the ACM validation records from the output before HTTPS works. | `helm_gdcn_version` 3.51.0 or newer |
| `ingress-nginx` | `letsencrypt` | `letsencrypt_email` set, and public port 80 reachable for the ACME challenge. | none |
| `istio_gateway` | `letsencrypt` | `letsencrypt_email` set, public NLB. Switching to or from Istio later needs a rollout restart of every workload. | `helm_gdcn_version` 3.53.0 or newer |

`acm` only works with `alb`; `letsencrypt` only works with `ingress-nginx` or
`istio_gateway`. A chart version with build metadata (`1.2.3+abc`) skips the
floor check.

## Optional blocks (leave commented unless asked)

- **Existing VPC:** `existing_vpc_id`, `existing_private_subnet_ids`, and
  `existing_public_subnet_ids` (at least two of each across two zones). The
  README "Use an existing VPC" section lists the subnet tags EKS and the load
  balancer controller need; without them the ALB never gets created.
- **AI Lake:** `enable_ai_lake = true` requires `ai_lake_size_profile` as well
  (`dev`, `prod-small`, or `prod-xl`) and an additional license. AI Lake exists
  on AWS only.
- **Image cache:** `enable_image_cache` with `dockerhub_username` and
  `dockerhub_access_token` avoids Docker Hub rate limits on larger profiles.
- **RDS overrides:** left unset they follow `size_profile`; prod profiles keep
  deletion protection and a final snapshot, `dev` does neither.

## Authenticate

The user runs one of these in their terminal:

```bash
aws sso login --profile <aws_profile_name>      # IAM Identity Center
aws configure --profile <aws_profile_name>      # access keys
```

Verify read-only before planning:

```bash
aws sts get-caller-identity --profile <aws_profile_name>
```

An SSO session that expires during a long apply or destroy fails with
"failed to refresh cached credentials". Log in again and re-run the same
command; Terraform picks up where it stopped.

## Apply

One phase. Expect the EKS cluster, RDS, and Karpenter to take most of the time,
then the Helm release with its 3600 second wait.

## Verify

```bash
terraform output ingress_controller
terraform output manual_dns_records        # dns_provider = "self-managed"
terraform output acm_validation_records    # tls_mode = "acm" with self-managed DNS
```

- With `route53`, records exist already; check `dig +short <org_hostname>`
  resolves to the load balancer.
- With `self-managed`, the user creates every record in `manual_dns_records`,
  and for `acm` the validation CNAMEs from `acm_validation_records`. The
  certificate stays pending, and HTTPS fails, until the validation records
  resolve.
- Then `curl -kIs https://<org_hostname>` should return 200 or a redirect to
  `auth_hostname`.

## Teardown notes for the report

- On `prod-*` profiles `terraform destroy` fails until the user applies
  `rds_deletion_protection = false` first.
- The ALB and Karpenter nodes are created by controllers inside the cluster.
  Terraform runs `scripts/alb-cleanup.sh` and `scripts/karpenter-drain.sh`
  during destroy; both can be re-run by hand if a destroy dies halfway.
