# GoodData.CN POC

Spin up a GoodData.CN proof-of-concept in the cloud in just a few minutes.

> **This deployment is for evaluation only – *not* production.**
> It creates cloud resources but without high availability or other considerations for production, though it can be used as a source of inspiration for a production-level setup. Deployment takes **≈20 minutes** and incurs normal cloud costs while running.

---

## How It Works

Terraform provisions:
  - **Cloud network** with public & private subnets across multiple zones
  - **Managed PostgreSQL** for GoodData metadata
  - **Object storage** for cache, data sources, and exports
  - **Managed Kubernetes cluster**
    - GoodData.CN
    - Apache Pulsar (for messaging)
    - ingress-nginx (ingress)
    - cert-manager (TLS)
    - Autoscaling and metrics support
    - Other cloud-specific prerequisites


Once everything is deployed, run `scripts/create-org.sh` to create your GoodData.CN organization and use `scripts/create-user.sh` whenever you need to add Dex-backed test users.

---

## Quickstart

### Setup
1. Install the following CLI utilities:
    - [Terraform](https://developer.hashicorp.com/terraform/install)
    - Cloud provider CLI ([AWS](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), [Azure](https://learn.microsoft.com/cli/azure/install-azure-cli))
    - [kubectl](https://kubernetes.io/docs/tasks/tools/)
    - [helm](https://helm.sh/docs/intro/install/)
    - [tinkey](https://developers.google.com/tink/tinkey-overview)
    - Standard utilities like `curl`, `openssl`, and `base64`
1. Have your GoodData.CN license key handy (your GoodData contact can help you with this)

> **Note:** If you want to skip the installation of all of the CLI utilities, a VS Code Dev Containers configuration is provided in this repo. Just install the extension into any compatible IDE and the repo will reopen with all utilities installed.

### Deploy

1. Clone the repo: `git clone https://github.com/gooddata/gooddata-cn-terraform.git`

1. Find out what the [latest version number of GoodData.CN is](https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/).

1. Copy the sample variables file for your provider and customize it:

    ```
    cp aws/settings.tfvars.example aws/settings.tfvars
    # or
    cp azure/settings.tfvars.example azure/settings.tfvars
    ```

    The example files document every available option (compute sizing, ingress/DNS choices, image caching, Helm chart versions, etc.). Update at least the GoodData.CN version (`helm_gdcn_version`), license key, contact email, and deployment name.

    - On AWS, `ingress_controller = "ingress-nginx"` (default) exposes the cluster through a wildcard DNS provider such as sslip.io. Set `ingress_controller = "alb"` to provision an AWS Application Load Balancer with Route53 + ExternalDNS managing hostnames. ALB mode **requires** `route53_zone_id`, automatically installs ExternalDNS, and only works with GoodData.CN Helm chart versions **3.51.0 or newer**.
    - Provide `base_domain` if you want predictable hostnames; otherwise Terraform derives `<deployment_name>.<route53_zone_name>` for ALB or `<deployment_name>.<ingress_ip>.<wildcard_dns_provider>` for ingress-nginx.
    - Azure currently supports ingress-nginx only. The Azure example file lists the same variables as the AWS file, minus the ALB-specific ones.

1. **Note:** If you will put significant load on the cluster, enable container image caching so you don't hit Docker Hub rate limits. Set `enable_image_cache = true` and provide `dockerhub_username` and `dockerhub_access_token` in your tfvars.

### DNS and multiple organizations

- Terraform outputs `base_domain`, `auth_domain`, `org_domains`, `org_ids`, and (when ALB is enabled) `alb_dns_name`. Run `terraform output -raw base_domain` after deployment to see the parent domain used for all hosts, `terraform output -json org_ids` or `terraform output -json org_domains` to inspect the configured organizations, and `terraform output -raw alb_dns_name` if you ever need to inspect the ALB target directly.
- Set `gdcn_org_ids` in your tfvars to control which organization IDs/DNS labels the cluster should trust. Each entry becomes `<org_id>.<base_domain>` (or `<org_id>.<ingress_ip>.<wildcard_dns_provider>` in wildcard mode) and is included in Dex `allowedOrigins`.
- The `scripts/create-org.sh` helper now reads that list. In `alb` mode it no longer prompts for a DNS label; instead it forces you to pick one of the configured IDs and automatically composes `<org_id>.<base_domain>` before ExternalDNS publishes the Route53 record. In ingress-nginx mode, you can keep the wildcard-generated hostname or type any fully qualified domain that already resolves to your ingress load balancer.
- Dex always lives at `auth.<base_domain>`, while each organization hostname becomes `<org_id>.<base_domain>`. If you override the wildcard DNS provider or supply your own `base_domain`, make sure the DNS records exist before running the scripts.

1. Choose your provider and `cd` into its directory: `cd aws` or `cd azure`

1. Authenticate to your cloud provider's CLI:
    - For AWS: `aws sso login` (or otherwise configure your AWS credentials)
    - For Azure: `az login`

1. Initialize Terraform: `terraform init`

1. Review what Terraform will deploy: `terraform plan -var-file=settings.tfvars`

1. Run Terraform: `terraform apply -var-file=settings.tfvars`

1. Once everything has been deployed, configure kubectl.
    - For AWS:

        ```
        aws eks update-kubeconfig \
            --name   "$(terraform output -raw eks_cluster_name)" \
            --region "$(terraform output -raw aws_region)" \
            --profile "$(terraform output -raw aws_profile_name)"
        ```

    - For Azure:

        ```
        az aks get-credentials \
            --resource-group "$(terraform output -raw azure_resource_group_name)" \
            --name "$(terraform output -raw aks_cluster_name)" \
            --overwrite-existing
        ```

1. Create the GoodData organization: `../scripts/create-org.sh`

1. Configure authentication according to your needs:
    - To use an external OIDC provider (recommended for anything beyond local testing), follow the [Set Up Authentication guide](https://www.gooddata.com/docs/cloud-native/latest/manage-organization/set-up-authentication/).
    - For quick local testing with the default Dex instance, create one or more users by running `../scripts/create-user.sh`. The script provisions the user in Dex and then creates or updates the corresponding GoodData user record by calling the public API ([Manage Users docs](https://www.gooddata.com/docs/cloud-native/3.49/manage-organization/manage-users/)).

1. Finally, open `https://<gdcn_org_hostname>` (exact address in Terraform output) and log in.

### Upgrading GoodData.CN

To upgrade GoodData.CN to the [latest version](https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/), follow these steps:

1. Check for any updates to this repo and pull them.

1. Open `settings.tfvars` and change the `helm_gdcn_version` variable to the latest value.

1. Run Terraform: `terraform apply -var-file=settings.tfvars`


### Tearing down

To delete all resources associated with the GoodData POC, follow these steps:

1. Delete any GoodData.CN organizations: `kubectl delete org --all -n gooddata-cn`

1. Run Terraform: `terraform destroy -var-file=settings.tfvars`


## Need help?

Reach out to your GoodData contact and they'll point you in the right direction!
