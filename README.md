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


Once everything is deployed, the `create-org.sh` script can be run to set up the first GoodData.CN organization.

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

1. Create a variables file called `settings.tfvars` for your provider.

    For AWS:
    ```terraform
    aws_profile_name       = "my-profile"      # as configured in ~/.aws/config
    aws_region             = "us-east-2"
    deployment_name        = "gooddata-cn-poc" # lowercase letters, numbers, and hyphens (start with a letter)
    helm_gdcn_version      = "<version>"       # from previous version (like 3.39.0)
    gdcn_license_key       = "key/asdf=="      # provided by your GoodData contact
    letsencrypt_email      = "me@example.com"  # can be any email address
    ```

    For Azure:
    ```terraform
    azure_subscription_id  = "00000000-0000-0000-0000-000000000000"
    azure_tenant_id        = "00000000-0000-0000-0000-000000000000"
    azure_location         = "East US"
    deployment_name        = "gooddata-cn-poc" # lowercase letters, numbers, and hyphens
    helm_gdcn_version      = "<version>"       # from previous version (like 3.39.0)
    gdcn_license_key       = "key/asdf=="      # provided by your GoodData contact
    letsencrypt_email      = "me@example.com"  # can be any email address
    ```

1. **Note:** If you will put significant load on the cluster, you'll want to set up container image caching so you don't hit the Docker Hub rate limits. Add these three lines to your config:

    For AWS:
    ```terraform
    ecr_cache_images       = true
    dockerhub_username     = "myusername"    # Docker Hub username (used to increase DH rate limit). Free account is enough.
    dockerhub_access_token = "myaccesstoken" # can be created in "Settings > Personal Access Token"
    ```

    For Azure:
    ```terraform
    acr_cache_images       = true
    dockerhub_username     = "myusername"    # Docker Hub username (used to increase DH rate limit). Free account is enough.
    dockerhub_access_token = "myaccesstoken" # can be created in "Settings > Personal Access Token"
    ```

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

1. Create the GoodData organization: `../create-org.sh`

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
