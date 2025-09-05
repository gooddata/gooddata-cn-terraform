# GoodData.CN Cloud POC

Spin up a GoodData.CN proof‑of‑concept in AWS or GCP in just a few minutes.

> This deployment is for evaluation only – not production.
> It creates real cloud resources (networking, Kubernetes, database, object storage, …) without high availability or other production considerations. Use it as a starting point for a production setup. A full deploy typically takes ≈20–30 minutes and incurs normal cloud costs.

---

## How it works

Terraform provisions a minimal‑but‑complete environment in your chosen cloud:
  - Networking: a new VPC with private subnets and egress via managed NAT
  - Kubernetes: managed cluster with autoscaling worker nodes and a static public IP for ingress
  - Database: managed PostgreSQL reachable privately from the cluster
  - Object storage: buckets for caches, user uploads, and exports
  - Kubernetes add‑ons: ingress‑nginx, cert‑manager, metrics‑server, and cloud‑specific storage classes/LB integration
  - GoodData.CN: installed via Helm with a small resource profile


Once everything is deployed, run `create-org.sh` to set up the first GoodData.CN organization.

---

## Quickstart

### Setup
1. Install the following CLI utilities:
    - Terraform, kubectl, helm
    - Cloud CLI: AWS CLI (v2) or gcloud
    - Tinkey (used to generate an encryption key)
    - Standard utilities: curl, openssl, base64
1. GoodData.CN license key (your GoodData contact can help you with this)

> **Note:** If you want to skip the installation of all of the CLI utilities, a VS Code Dev Containers configuration is provided in this repo. Just install the extension into any compatible IDE and the repo will reopen with all utilities installed.

### Deploy

1. Clone the repo: `git clone https://github.com/gooddata/gooddata-cn-terraform.git`

1. Find out what the [latest version number of GoodData.CN is](https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/).

1. Create a variables file called `settings.tfvars`:
    - For AWS:
      ```terraform
      aws_profile_name       = "my-profile"      # as configured in ~/.aws/config
      aws_region             = "us-east-2"
      deployment_name        = "gooddata-cn-poc" # lowercase, <20 chars
      helm_gdcn_version      = "<version>"       # e.g., 3.39.0
      gdcn_license_key       = "key/asdf=="
      letsencrypt_email      = "me@example.com"
      ```
    - For GCP:
      ```terraform
      gcp_project_id         = "my-project-id"
      gcp_region             = "us-central1"
      deployment_name        = "gooddata-cn-poc"
      helm_gdcn_version      = "<version>"
      gdcn_license_key       = "key/asdf=="
      letsencrypt_email      = "me@example.com"
      ```

1. Optional: container image caching to avoid Docker Hub rate limiting
    - For AWS (ECR pull‑through cache):
      ```terraform
      ecr_cache_images       = true
      dockerhub_username     = "myusername"    # Docker Hub username (used to increase DH rate limit)
      dockerhub_access_token = "myaccesstoken" # Docker Hub Personal Access Token
      ```
    - For GCP (Artifact Registry remotes):
      ```terraform
      ar_cache_images         = true
      dockerhub_username      = "myusername"    # required if ar_cache_images = true
      dockerhub_access_token  = "myaccesstoken" # required if ar_cache_images = true
      ```

1. `cd` into `aws` or `gcp`, depending on your target cloud

1. Authenticate to your cloud provider's CLI (e.g., `aws sso login` or `gcloud auth login`)

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
    - For GCP:

        ```
        gcloud container clusters get-credentials \
            "$(terraform output -raw gke_cluster_name)" \
            --region  "$(terraform output -raw gcp_region)" \
            --project "$(terraform output -raw gcp_project_id)"
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
