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
    - For AWS: `aws login` / `aws sso login` (or otherwise configure your AWS credentials)
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

1. Finally, open your GoodData.CN URL and log in.
    - For cloud deployments: open `https://<gdcn_org_hostname>` (exact address in Terraform output).
   - For local deployments: open `https://localhost` (you will see a browser warning because the certificate is self-signed).

### Upgrading GoodData.CN

To upgrade GoodData.CN to the [latest version](https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/), follow these steps:

1. Check for any updates to this repo and pull them.

1. Open `settings.tfvars` and change the `helm_gdcn_version` variable to the latest value.

1. Run Terraform: `terraform apply -var-file=settings.tfvars`


### Tearing down

To delete all resources associated with the GoodData POC, follow these steps:

1. Run Terraform: `terraform destroy -var-file=settings.tfvars`


## Need help?

Reach out to your GoodData contact and they'll point you in the right direction!
