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

#### Upgrading from ingress-nginx to Traefik

Traefik replaces ingress-nginx. Rename `ingress_nginx_behind_l7` to `ingress_behind_l7` and `helm_ingress_nginx_version` to `helm_traefik_version` in `settings.tfvars`. Set `ingress_controller = "traefik"` if you set it before.

During `terraform apply`, Terraform removes the ingress-nginx namespace and its load balancer. It then creates Traefik with a new load balancer. Expect a short outage, and update your DNS record if it does not follow the load balancer automatically.

Ingresses that the GoodData.CN organization controller already created keep `ingressClassName: nginx` until something changes them. A one-time Kubernetes Job (`ingress-class-migration` in the `traefik` namespace) changes only those Ingresses to `traefik`. It does nothing on a new installation. To check, run this command and confirm that no row shows `nginx`:

```bash
kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName
```

If `gdcn_helm_extra_values` sets `ingress.ingressClassName: nginx`, remove that setting before the upgrade. It overrides the Traefik class, so the organization controller would create new Ingresses with class `nginx` again. If `ingressClassName` is the only key under `ingress`, remove the `ingress:` key too: an empty `ingress:` is `null` and deletes the chart's ingress values.


### Tearing down

To delete all resources associated with the GoodData POC, follow these steps:

1. Run Terraform: `terraform destroy -var-file=settings.tfvars`


## FIPS mode (AWS)

Set `fips_enabled = true` to prepare the AWS infrastructure for a FIPS validation run. This covers infrastructure and the AWS endpoints of the applications. It does not make the GoodData.CN containers FIPS-capable. Use `gdcn_helm_extra_values` for the application FIPS values.

What the switch does:

- Uses Bottlerocket FIPS AMIs for the system node group and for Karpenter nodes. The Karpenter AMI ID is read from the public SSM parameter `/aws/service/bottlerocket/aws-k8s-<eks_version>-fips/<arch>/latest/image_id` at every plan. A new AMI ID changes the EC2NodeClass and causes Karpenter drift: all workload nodes are replaced in a rolling way. To avoid this, set `karpenter_fips_ami_id` to a fixed AMI ID.
- Sets the AWS provider to `use_fips_endpoint` (the IAM Identity Center portal has no FIPS endpoint, so the provider keeps the normal SSO portal endpoint for SSO profiles) and sets `AWS_USE_FIPS_ENDPOINT=true` in Karpenter, the AWS Load Balancer Controller, external-dns and the EBS CSI driver.
- Uses the `ecr-fips` registry host for the image cache.
- Without `s3_endpoint`: sets the chart value `global.aws.useFipsEndpoint: true`, so every GoodData.CN container calls the AWS FIPS endpoints (S3, STS for IRSA). The exports URL uses the S3 FIPS host `s3-fips.<region>.amazonaws.com`. Loki gets no S3 endpoint and `AWS_USE_FIPS_ENDPOINT=true`, so its SDK selects the FIPS host. Tempo (minio-go does not read the variable) gets the S3 FIPS host. Both get `AWS_STS_REGIONAL_ENDPOINTS=regional`. This needs a chart with the value (an older chart ignores it). Langfuse and the AI Lake StarRocks have their own S3 settings and are not changed. With `s3_endpoint`, see "Object-storage endpoints".
- Requires TLS for RDS (`rds.force_ssl=1`). Terraform downloads the regional RDS CA bundle (`https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`), creates the Secret `postgres-ca-cert` from it and points `genAi.database.sslRootCert` at it. To get `verify-full`, set `genAi.database.sslMode: verify-full` (and, with AI Lake, `aiLake.database.sslMode` and `aiLake.database.sslRootCert`) with `gdcn_helm_extra_values` or `gdcn_helm_extra_values_files`. The other connections (the GoodData.CN base values for the Java services, Dex, Langfuse and the bootstrap Jobs) use `sslmode=require` (encrypted, server certificate not verified).
- Requires `ingress_controller = "istio_gateway"` (and `tls_mode = "letsencrypt"`). No other ingress controller is allowed. This module always installs Istio in sidecar mode with STRICT mTLS for the GoodData.CN namespaces, so no extra toggle exists.
- Enables `istio_gateway_fips_tls`.
- Fails the plan in a region without FIPS endpoints (only the US commercial regions us-east-1, us-east-2, us-west-1 and us-west-2 are allowed).

`rds.force_ssl=1` is explicit for clarity. PostgreSQL 15 and later already default to 1.

Verify in the AWS run: the Karpenter pricing refresh and the AWS Load Balancer Controller Shield and WAF calls under FIPS endpoints. Some of these APIs may have no FIPS endpoint.

Not covered: the S3 gateway VPC endpoint (it has no FIPS variant), the EKS API endpoint used by `aws eks get-token`, the EKS pod identity agent, and the Route 53 and Elastic Load Balancing calls of in-cluster controllers where the SDK or chart does not honor `AWS_USE_FIPS_ENDPOINT`.

### Object-storage endpoints

Every object-storage client in the cluster has an explicit endpoint setting. One rule applies to all of them:

- An explicit endpoint is used as it is. The client then gets no `AWS_USE_FIPS_ENDPOINT`, because the AWS SDKs refuse a custom endpoint together with it ("A custom endpoint cannot be combined with FIPS"). If you need FIPS, give the FIPS host yourself.
- Without an explicit endpoint on AWS with `fips_enabled = true`, the SDKs select the FIPS endpoints through `AWS_USE_FIPS_ENDPOINT`.

| Cloud | Variable | Default | Clients |
|---|---|---|---|
| AWS | `s3_endpoint` (host or `https://host[:port]`) | empty: AWS default endpoint, FIPS through the SDK under `fips_enabled` | GoodData.CN storage (exports, Quiver cache, data source files, geo collections, map ingestion job), Loki, Tempo, Langfuse, StarRocks |
| Azure | `azure_storage_endpoint_suffix` | `core.windows.net` | GoodData.CN storage (`<account>.blob.<suffix>`, `<account>.dfs.<suffix>`), Loki, Tempo, Langfuse |
| local | `local_s3_endpoint_override` (SeaweedFS) | in-cluster SeaweedFS | all |

With `s3_endpoint` set on AWS, `global.aws.useFipsEndpoint` stays `false` for the whole GoodData.CN chart (the chart fails on an explicit endpoint together with it), and Loki gets only `AWS_STS_REGIONAL_ENDPOINTS=regional`. Example for FIPS with an explicit host: `s3_endpoint = "s3-fips.us-east-1.amazonaws.com"`. STS (IRSA) then uses the regional non-FIPS STS host unless you set it some other way. For Azure Government, set `azure_storage_endpoint_suffix = "core.usgovcloudapi.net"`; the azurerm provider environment and the other Azure hosts are not changed by this variable.

For arm64 (Graviton) nodes, set `eks_node_arch = "arm64"`. The system node group uses the Graviton `m8g` type of the size profile (fallback `m7g`) and Karpenter selects Graviton `m` instances. All nodes use one architecture. With `enable_ai_lake = true`, also set `eks_ai_lake_node_types` to arm64 instance types.

## Geo charts (basemap)

`geo_basemap_provider` selects the map behind pushpin and area charts:

| Value | Map service | Notes |
|---|---|---|
| `awslocation` | Amazon Location Service (AWS only), signed by api-gw through IRSA | The Terraform adds the `geo-maps` IAM policy. Amazon Location has no FIPS endpoint outside `us-gov-west-1`: do not use it in FIPS mode. |
| `mapbox` | Mapbox (SaaS), token in `geo_mapbox_token` | Needs internet access from api-gw. |
| `protomaps` | **Self-contained.** An in-cluster OpenStreetMap basemap (Protomaps PMTiles). | No external service at runtime, works air-gapped, tile traffic stays in the cluster/mesh. |
| `none` (default) | None | Geo charts are off (chart value `apiGw.locationService.plugin: none`, charts newer than 4.16). |

### `protomaps`

The module deploys `gdcn-basemap` in the GoodData.CN namespace: a Deployment and Service (image `geo_protomaps_image`,
built from gdc-nas `tools/basemap-image`), a PVC with the tile archive, and a ConfigMap with the MapLibre style
(Protomaps "light", OpenStreetMap/ODbL attribution). The chart's `CustomLocation` plugin points at the style;
api-gw proxies every tile, glyph and sprite. Glyphs and sprites are in the image.

The tile archive comes from one of two sources:

- Download (default): a Job cuts `geo_protomaps_source_url` to `geo_protomaps_bbox` and `geo_protomaps_max_zoom`.
  The default is the public Protomaps daily build, contiguous United States, zoom 0-10. Daily builds are removed
  after some days, so pin a current one (`https://build.protomaps.com/YYYYMMDD.pmtiles`, list:
  `https://build-metadata.protomaps.dev/builds.json`) or mirror the file. The Job needs internet access only once.
- Air-gapped: copy a `.pmtiles` file to an internal http(s):// or s3:// URL and set `geo_protomaps_source_url` to it
  (the Job cuts it the same way), or put `basemap.pmtiles` on your own PVC and set `geo_protomaps_existing_claim`
  (no Job runs; make the extract on a connected machine with `pmtiles extract <source> basemap.pmtiles --bbox=... --maxzoom=...`).

A changed source, area or zoom creates a new Job, which replaces the archive. Measured sizes (build 20261111):
contiguous US z0-10 386 MB, US z0-12 1.9 GB (68 s); Czechia z0-12 255 MB. The download of a US z10 extract takes about 20 s.
Size `geo_protomaps_storage_size` (default 10Gi) to fit.

## Autoscaling

Set `enable_gdcn_autoscaling = true` (requires chart >= 4.12.0) to horizontally autoscale the GoodData.CN services. See [Configure Autoscaling in GoodData.CN](https://www.gooddata.com/docs/cloud-native/latest/install/installation-configuration/autoscaling/) for prerequisites, which services scale, and how to tune or disable it.

## Hardening

The module always applies these settings: the license key and the encryption keyset are in Secrets, each service has its own PostgreSQL user, telemetry is off and the tools pod is not deployed. With `ingress_controller = "istio_gateway"`, the module also sets STRICT mTLS in the GoodData.CN and Pulsar namespaces.

Use these variables for more hardening. Each variable is off or empty by default. Values in `gdcn_helm_extra_values` override the values from these variables.

| Variable | Default | What it sets |
|---|---|---|
| `gdcn_hardened` | `false` | `restrictedPodSecurity.enabled: true` and the restricted security contexts for the `redis-ha` and `qdrant` subcharts. All pods run as non-root with a read-only root filesystem. Needs chart 4.15.0 or later. |
| `gdcn_deploy_dex` | `true` | `deployDexIdP`. Set `false` only after each organization uses your own OIDC identity provider. |
| `gdcn_embedding_origins` | `null` | `settings.embeddingOrigins`. Set the origins of the pages that embed dashboards, or `[]` for none. |
| `gdcn_hardening_next_release` | `{}` | Values for a GoodData.CN release after 4.15.1: `db_ssl_mode` and `db_ssl_root_cert` (`service.postgres.sslMode`, `sslRootCert`), `fips_mode` and `fips_allow_non_fips_host` (`global.fips.*`), `aws_use_fips_endpoint` (`global.aws.useFipsEndpoint`), `export_egress_mode` and `export_egress_allowed_hosts` (`exportBuilder.egress.*`). The module does not set an attribute that is `null`. |

Before you set `gdcn_hardened = true` on a deployment that has data, read this: all pods restart, and the first start changes the group owner of the files on each volume. On large etcd or Quiver volumes, this can take long enough to fail the startup probes. Test on a copy first.

The module does not turn on network policies. To use them, set `networkPolicy.*` in `gdcn_helm_extra_values` on a CNI that enforces them.

For all hardening steps, refer to [Harden the Deployment](https://www.gooddata.com/docs/cloud-native/latest/install/installation-configuration/security-hardening/).

## Observability

Set `enable_observability = true` and `observability_hostname` in your `settings.tfvars` to deploy the observability stack (Prometheus, Loki, Tempo, and Grafana).

After `terraform apply`, Grafana is available at `https://<observability_hostname>`. A GoodData-CN health dashboard is automatically provisioned and can be found under the **GoodData-CN** folder in Grafana.

To import the dashboard into a standalone Grafana instance, upload `modules/k8s-common/dashboards/gooddata-cn-overall-health.json` via **Dashboards → Import** and replace the datasource UIDs (`prometheus` → your Prometheus UID, `loki` → your Loki UID).

## LLM observability

Set `enable_llm_observability = true`, `llm_observability_hostname` and `langfuse_admin_email` in your `settings.tfvars` to deploy [Langfuse](https://langfuse.com/) and send traces from the gen-ai services to it. This also requires `enable_ai_features = true`, since those services are what produce the traces. Langfuse brings its own ClickHouse, Keeper, and Valkey pods, so expect it to add a few GB of memory to the cluster.

After `terraform apply`, Langfuse is available at `https://<llm_observability_hostname>`. Traces appear within a few seconds of using any AI feature, tagged with `langfuse_tracing_environment` (`dev` unless you change it).

An admin user is created on the first apply, and self-registration is disabled, so this is the only account. Read its credentials from the Terraform output in your provider directory:

```bash
terraform output langfuse_admin_email
terraform output -raw langfuse_admin_password
```

Invitations are not wired up (Langfuse blocks sign-up before it checks them), so treat this output as a shared deployment secret and keep it within the team that already has cluster access.

## Installing an internal build (GoodData employees)

> Internal only — the registry is unreachable outside GoodData. Leave these unset
> to install the released chart. `<registry>` is in the internal deployment docs.

1. Run the **adhoc: Build** pipeline. You can set `deploy_to_adhoc=false` since we'll deploy here instead.
1. Copy the chart version from its *Generate version used by chart/images* step.
   The `<sha>` in it is also the image tag.
1. Add to `settings.tfvars` in any environment:

    ```hcl
    internal_chart_repository     = "oci://<registry>/helm/gooddata/adhoc"
    helm_gdcn_version             = "0.1.<timestamp>+<sha>"
    internal_registry_server      = "<registry>"
    internal_registry_aws_profile = "<profile>"

    # The chart pins image tags but not the registry, and ships no UI tags at all.
    # Without both of these, components resolve to Docker Hub (no branch builds are
    # published there) and the UI to an empty tag.
    gdcn_helm_extra_values = <<-EOT
      image:
        repositoryPrefix: <registry>/nas-testing
      analyticalDesigner: { image: { repositoryPrefix: gooddata, tag: "<released-version>" } }
      dashboards:         { image: { repositoryPrefix: gooddata, tag: "<released-version>" } }
      homeUi:             { image: { repositoryPrefix: gooddata, tag: "<released-version>" } }
      hostApplication:    { image: { repositoryPrefix: gooddata, tag: "<released-version>" } }
      webComponents:      { image: { repositoryPrefix: gooddata, tag: "<released-version>" } }
    EOT
    ```

1. Run `terraform apply -var-file=settings.tfvars`

### Use a local chart directory

To test a chart that you build on your machine, set `gdcn_chart_path` to the chart directory
(for example a checkout of the `gooddata-cn` chart). Terraform then ignores `internal_chart_repository`
and the chart version. Set `helm_gdcn_version` to a value that contains `+` (for example `0.0.0+local`)
to skip the version checks.

```hcl
gdcn_chart_path   = "/path/to/gdc-nas/helm/gooddata-cn"
helm_gdcn_version = "0.0.0+local"
```

For local images, use `k3d image import` and set the image prefix and tag in `gdcn_helm_extra_values`.

## Need help?

Reach out to your GoodData contact and they'll point you in the right direction!
