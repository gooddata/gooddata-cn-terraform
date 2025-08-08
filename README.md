# GoodData.CN Cloud POC

Spin up a GoodData.CN proof-of-concept in the cloud in just a few minutes.

> **This deployment is for evaluation only – *not* production.**
> It creates real AWS resources (EKS, RDS, S3, …) but without high availability or other production considerations. It can be used as a source of inspiration for a production-level setup. Deployment takes **≈20 minutes** and incurs normal AWS costs while running.

---

## How It Works

Terraform provisions:
  - **Amazon VPC** with public & private subnets across two AZs
  - **Amazon RDS (PostgreSQL)** for GoodData metadata
  - **Amazon S3** buckets for cache, data sources, and exports
  - **Amazon EKS** with autoscaling worker nodes
    - GoodData.CN
    - Apache Pulsar (for GoodData.CN messaging handling)
    - ingress-nginx (for handling requests)
    - cert-manager (for provisioning TLS certificates for ingress)
    - Other cloud-specific requirements


Once everything is deployed, the `create-org.sh` script can be run to set up the first GoodData.CN organization.

---

## Quickstart

### Setup
1. Install the following CLI utilities:
    - [Terraform](https://developer.hashicorp.com/terraform/install)
    - Cloud provider CLI ([AWS](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
    - [kubectl](https://kubernetes.io/docs/tasks/tools/)
    - [helm](https://helm.sh/docs/intro/install/)
    - [tinkey](https://developers.google.com/tink/tinkey-overview)
    - Standard utilities like `curl`, `openssl`, and `base64`
1. GoodData.CN license key (your GoodData contact can help you with this)

> **Note:** If you want to skip the installation of all of the CLI utilities, a VS Code Dev Containers configuration is provided in this repo. Just install the extension into any compatible IDE and the repo will reopen with all utilities installed.

### Deploy

1. Clone the repo: `git clone https://github.com/gooddata/gooddata-cn-terraform.git`

1. Find out what the [latest version number of GoodData.CN is](https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/).

1. Create a variables file called `settings.tfvars` that looks like this:
    ```terraform
    aws_profile_name       = "my-profile"      # as configured in ~/.aws/config
    aws_region             = "us-east-2"
    deployment_name        = "gooddata-cn-poc" # can be any lowercase string shorter than 20 characters
    helm_gdcn_version      = "<version>"       # from previous version (like 3.39.0)
    gdcn_license_key       = "key/asdf=="      # provided by your GoodData contact
    letsencrypt_email      = "me@example.com"  # can be any email address
    ```

1. **Note:** If you will put significant load on the cluster, you'll want to set up container image caching so you don't hit the Docker Hub rate limits. Add these three lines to your config:
    ```terraform
    ecr_cache_images       = true
    dockerhub_username     = "myusername"    # Docker Hub username (used to increase DH rate limit). Free account is enough.
    dockerhub_access_token = "myaccesstoken" # can be created in "Settings > Personal Access Token"
    ```

1. `cd` into the directory of the cloud provider you'll be deploying to (ex. `aws`)

1. Authenticate to your cloud provider's CLI (ex. `aws sso login`)

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
