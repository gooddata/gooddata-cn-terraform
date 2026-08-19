# GoodData.CN POC

Spin up a GoodData.CN deployment in the cloud in just a few minutes.

> **This deployment is for evaluation only – *not* production.**
>It can be used as a source of inspiration for a production-level setup, but this project is not versioned and is not officially supported by GoodData in production.

---

## How It Works

Terraform provisions:
  - **Cloud network** with public & private subnets across multiple zones
  - **Managed PostgreSQL** for GoodData metadata
  - **Object storage** for cache, data sources, and exports
  - **Managed Kubernetes cluster**
    - GoodData.CN
    - Apache Pulsar (for messaging)
    - Ingress controller
    - Other cloud-specific prerequisites

## Quickstart

### Setup
1. Install the following CLI utilities:
    - [Terraform](https://developer.hashicorp.com/terraform/install)
    - Cloud provider CLI ([AWS](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), [Azure](https://learn.microsoft.com/cli/azure/install-azure-cli))
    - For Azure deployments: [kubelogin](https://azure.github.io/kubelogin/install.html)
    - [kubectl](https://kubernetes.io/docs/tasks/tools/)
    - [helm](https://helm.sh/docs/intro/install/)
    - For local deployments:
      - [Docker](https://docs.docker.com/get-docker/)
      - [k3d](https://k3d.io/)
    - [tinkey](https://developers.google.com/tink/tinkey-overview)
    - Standard utilities like `curl`, `openssl`, and `base64`
1. Have your GoodData.CN license key handy (your GoodData contact can help you with this)

> **Note:** If you want to skip the installation of all of the CLI utilities, a VS Code Dev Containers configuration is provided in this repo. Just install the extension into any compatible IDE and the repo will reopen with all utilities installed.

### (optional, AWS only) Use an existing VPC

By default Terraform creates a new VPC. If your IT team has already provisioned a VPC for the PoC, you can deploy into it instead by setting three variables in `aws/settings.tfvars`:

```hcl
existing_vpc_id             = "vpc-0123456789abcdef0"
existing_private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
existing_public_subnet_ids  = ["subnet-ccc", "subnet-ddd"]
```

Requirements:
- The VPC must have **DNS hostnames** and **DNS support** enabled.
- Provide at least **2 private** and **2 public** subnet IDs, spanning at least 2 availability zones.
- Private subnets are used for EKS nodes and RDS; public subnets are used for load balancers.
- Subnets must carry the following tags for the AWS Load Balancer Controller and EKS to discover them:
  - **Public subnets:** `kubernetes.io/role/elb = 1` and `kubernetes.io/cluster/<deployment_name> = shared`
  - **Private subnets:** `kubernetes.io/role/internal-elb = 1` and `kubernetes.io/cluster/<deployment_name> = shared`

### Deploy

1. Clone the repo: `git clone https://github.com/gooddata/gooddata-cn-terraform.git`

1. Copy the sample variables file for your provider and customize it:

    ```
    cp aws/settings.tfvars.example aws/settings.tfvars
    # or (for azure)
    cp azure/settings.tfvars.example azure/settings.tfvars
    # or (for local)
    cp local/settings.tfvars.example local/settings.tfvars
    ```

    The example file has good defaults but you may want to modify it based on your needs.

1. Choose your provider and `cd` into its directory: `cd aws`, `cd azure`, or `cd local`

1. Authenticate to your cloud provider's CLI:
    - For AWS: authenticate the profile named by `aws_profile_name` in
      `settings.tfvars`, since Terraform uses it regardless of your default
      profile. For an IAM Identity Center (SSO) profile that is
      `aws sso login --profile <aws_profile_name>`; for access keys it is
      `aws configure --profile <aws_profile_name>`.
    - For Azure: `az login`
    - Azure note: Terraform's Kubernetes authentication uses `kubelogin` with your Azure CLI session.

1. Initialize Terraform: `terraform init`

1. Review what Terraform will deploy: `terraform plan -var-file=settings.tfvars`

1. Run Terraform:
    - For cloud deployments: `terraform apply -var-file=settings.tfvars`
    - For local deployments, first create the cluster, then apply everything else:

        ```
        terraform apply -target=null_resource.k3d_cluster -var-file=settings.tfvars
        terraform apply -var-file=settings.tfvars
        ```

1. Once everything has been deployed, configure kubectl: `../scripts/configure-kubectl.sh`

1. If you set `gdcn_orgs`, Terraform already created the organizations. Otherwise, you can create those manually now.

1. Configure authentication according to your needs:
    - To use an external OIDC provider (recommended for anything beyond local testing), follow the [Set Up Authentication guide](https://www.gooddata.com/docs/cloud-native/latest/manage-organization/set-up-authentication/).
    - For quick testing with the default IdP (Dex), create one or more users by staying in the provider directory (`aws`, `azure`, or `local`) and running `../scripts/create-user.sh`. If Terraform created the organization, the script will automatically read the admin credentials from the Secret `gooddata-cn/gdcn-org-admin-<org_id>`.

1. **(Optional)** If you enabled the observability stack (`enable_observability = true`), create Grafana users by running `../scripts/create-grafana-user.sh` from your provider directory. The script creates a Grafana user and optionally promotes them to admin. It automatically reads the Grafana admin credentials from the Kubernetes secret.

1. Finally, open your GoodData.CN URL and log in.
    - For cloud deployments: open `https://<gdcn_org_hostname>` (exact address in Terraform output).
    - For local deployments: open `https://gooddata.localhost` (you will see a browser warning because the certificate is self-signed).

### Upgrading GoodData.CN

To upgrade GoodData.CN to the [latest version](https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/), follow these steps:

1. Check for any updates to this repo and pull them.

1. Open `settings.tfvars` and change the `helm_gdcn_version` variable to the latest value.

1. Run Terraform: `terraform apply -var-file=settings.tfvars`


### Tearing down

To delete all resources associated with the GoodData POC, follow these steps:

1. Run Terraform: `terraform destroy -var-file=settings.tfvars`


## Observability

Set `enable_observability = true` and `observability_hostname` in your `settings.tfvars` to deploy the observability stack (Prometheus, Loki, Tempo, and Grafana).

After `terraform apply`, Grafana is available at `https://<observability_hostname>`. A GoodData-CN health dashboard is automatically provisioned and can be found under the **GoodData-CN** folder in Grafana.

To import the dashboard into a standalone Grafana instance, upload `modules/k8s-common/dashboards/gooddata-cn-overall-health.json` via **Dashboards → Import** and replace the datasource UIDs (`prometheus` → your Prometheus UID, `loki` → your Loki UID).

## Autoscaling

GoodData.CN services scale horizontally on CPU utilization. This is **enabled by default** and requires `helm_gdcn_version >= 4.12.0`; set `enable_gdcn_autoscaling = false` in your `settings.tfvars` to turn it off (required if you pin an older chart).

### What gets deployed

- **[KEDA](https://keda.sh/)** in the `keda` namespace — the chart renders a `ScaledObject` per component, and the KEDA operator reconciles each into a Kubernetes HPA.
- **Kubernetes Metrics Server** on AWS only — the CPU trigger reads from it, and EKS does not ship it (AKS and k3d already include it).

### Which components autoscale

Nine components, each scaling independently. Replica bounds come from the size profile; CPU targets and scale-up/scale-down behavior come from the chart defaults.

| Component | Role | CPU target | Replicas (`dev`) | Replicas (production) |
|---|---|---|---|---|
| `metadata-api` | metadata read/write, most-called service | 75% | 1–3 | 2–5 |
| `api-gw` | primary HTTP gateway | 75% | 1–3 | 2–5 |
| `auth-service` | authentication | 75% | 1–3 | 2–5 |
| `afm-exec-api` | execution orchestration | 60% | 1–3 | 2–5 |
| `calcique` | MAQL → SQL compilation | 60% | 1–3 | 2–5 |
| `result-cache` | result caching and paging | 60% | 1–3 | 2–5 |
| `analytical-designer` | UI (static assets) | 80% | 1–3 | 2–5 |
| `dashboards` | UI (static assets) | 80% | 1–3 | 2–5 |
| `home-ui` | UI (static assets) | 80% | 1–3 | 2–5 |

`host-application` and `web-components` are also opted in, but chart 4.12.0 and 4.12.1 render no `ScaledObject` for them, so they run at their profile replica count until you upgrade to a chart release that adds one. Their CPU request is 50m either way, which is what keeps them scheduled accurately in the meantime.

CPU utilization is measured against each container's **CPU request**, not its limit. Scale-up is quick (60s stabilization; `metadata-api` uses 300s to absorb JVM warmup after a deploy) and scale-down is deliberately slow to avoid flapping, with chart-default stabilization windows of 15 minutes for the static UI frontends, 30 minutes for most services and 60 minutes for `metadata-api`. No component scales to zero — JVM cold start is 30–40s.

Stateful and quorum-based components are intentionally **not** autoscaled: PostgreSQL, Redis, etcd, Pulsar, and Qdrant. Adding replicas there is either unsupported or requires a data-rebalancing step.

On AWS, pod scaling is backed by node scaling: Karpenter provisions nodes as pods are added, up to the vCPU ceiling of your `size_profile`.

### Tuning and disabling

Override any per-component setting through `gdcn_helm_extra_values`, for example to raise a ceiling:

```hcl
gdcn_helm_extra_values = <<-EOT
  metadataApi:
    kedaAutoscaling:
      maxReplicaCount: 8
EOT
```

Setting `enable_gdcn_autoscaling = false` removes KEDA and the `ScaledObject`s. Deployments keep whatever replica count they had at that moment, so scale in manually afterwards if you want to reclaim the capacity.

## Need help?

Reach out to your GoodData contact and they'll point you in the right direction!
