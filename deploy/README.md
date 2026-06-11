# Independent GoodData CN deployment

Deploys GoodData CN on AWS (EKS + RDS + S3) using the terraform module in this
repo (`../aws`), for **local inference / BYOLLM testing** with a custom gen-ai
image. ~$15/day per environment — destroy when not in use.

Based on the approach from `Tomkess/gdc-cn-independent-deploy`, restructured to
live next to the terraform module (no external clone) and support multiple
environments.

## Environments

Each environment lives in `deploy/envs/<env>/settings.tfvars` and has its own
Terraform state in S3 (`independent-deploy/<env>/terraform.tfstate`), its own
hostname, and its own feature-flag set.

| Environment | URL | Purpose |
|---|---|---|
| `local-inference` | https://gooddata.local-inference.dev11.devgdc.com | local inference testing (SIE / vLLM / BYOLLM) |

**Inference-server testing note:** different inference servers (SIE, vLLM, TGI…)
do NOT need separate environments — the server lives outside the cluster.
Register each as a separate LLM provider entity (distinct `PROVIDER_ID`) in one
environment and switch between them. A new environment is only warranted per
*person*, to avoid stepping on each other's state.

## Prerequisites

- Terraform, AWS CLI (SSO profile `aws-panther-dev`), kubectl, helm
- tinkey + GNU coreutils (`brew install coreutils`)

## Quick start

```bash
# 1. License key (committed tfvars keep it empty on purpose)
export GDCN_LICENSE_KEY="key/..."

# 2. Initialize Terraform for your environment (once, or when switching envs)
./deploy/deploy.sh local-inference init

# 3. Deploy (~35 min)
./deploy/deploy.sh local-inference apply
```

## Commands

| Command | Description |
|---|---|
| `./deploy.sh <env> init` | Initialize Terraform for `<env>` — run once, or when switching environments |
| `./deploy.sh <env> apply` | Deploy / update the environment |
| `./deploy.sh <env> destroy` | Tear down all resources |
| `./deploy.sh <env> status` | Show Terraform outputs (URLs, cluster name) |
| `./deploy.sh <env> kubectl` | Reconfigure kubectl for the deployed cluster |

The script handles SSO refresh automatically and refuses to `apply`/`destroy`
an environment other than the one Terraform is currently initialized for
(state-safety guard — re-run `init` to switch).

## Feature flags

Configured per environment in `deploy/envs/<env>/settings.tfvars` under
`gdcn_helm_extra_values`. Toggle and re-run `apply` (~2 min, no infra
recreation). The four core AI flags (`enableSemanticSearch`, `enableGenAIChat`,
`enableAiAgenticConversations`, `enableGenAIMemory`) must stay `true`.

`local-inference` additionally enables: `enableAIKnowledge`,
`enableSemanticSearchInChat`, `enableAiHub`, `enableGenAiVisualizationSkill`,
`enableGenAiVisualizationSummarySkill`, `enableGenAiDashboardSummarySkill`,
`enableGenAIReasoningVisibility`.

## Custom gen-ai image

To test a gdc-nas branch build (e.g. `jan/local-inference` with the LOCAL
provider + Chat Completions adapter), uncomment the `services.genAi.image`
block at the bottom of the env's `gdcn_helm_extra_values` and re-run `apply`.
The image must already exist in ECR — build via the GitHub Actions workflow
(below), or locally:

```bash
cd gdc-nas
docker buildx build --platform linux/amd64 \
  -t 020413372491.dkr.ecr.us-east-1.amazonaws.com/dev/mark43-ai:<tag> \
  --push microservices/gen-ai/
```

## Inference strategy: SIE self-hosted in OUR cluster

**SIE (Superlinked Inference Engine) runs in our EKS on our GPU pool** —
their engine, our infrastructure, nothing leaves the VPC. Their helm chart
is public (`oci://ghcr.io/superlinked/charts/sie-cluster`, images on ghcr)
and its AWS profile maps exactly to our `g6.xlarge` (NVIDIA L4) pool.

```bash
./deploy/deploy.sh local-inference kubectl
./deploy/helm/install-sie.sh      # gateway + NATS + 1 warm L4 worker (sglang bundle)
```

In-cluster endpoint: `http://sie-gateway.sie.svc.cluster.local:8080/v1`
(gateway auth `none`, ClusterIP only). Architecture: gateway → NATS
JetStream → GPU worker; models load lazily from Hugging Face on first
request (their docs: 3–7 min cold start; one warm worker is kept, so this
applies only to the first request per model).

**Model sizing on L4 (24 GB):** start with a small generative model from
their bundle (e.g. `Qwen/Qwen3-0.6B`) to validate the pipeline.
**Qwen3.6-27B via SIE needs `a100-80gb`-class hardware** (chart profiles:
l4 / a100-40gb / a100-80gb; no FP8 profile for L40S exists today) — that's
an agenda item with Superlinked (~Jun 22): FP8/quantized 27B bundle, or we
add an A100 pool ($$$). For a 27B *today* on cheap HW, the vLLM alternative
below does FP8 on a single L40S.

**Alternative server on the same pool: vLLM** (`deploy/k8s/vllm-qwen.yaml`,
Qwen3.6-27B FP8 on `g6e.xlarge`) — switch the pool instance type in tfvars,
apply, and `REGISTER_VLLM=true`. Useful as an A/B server comparison
(SIE vs vLLM), which is exactly the M1 evaluation track.

## Registering LLM providers

After deployment, register the inference backend(s) as LOCAL providers:

```bash
cp deploy/providers/providers.env.example deploy/providers/providers.env
# fill in TIGER_API_TOKEN (org token)
./deploy/providers/register-providers.sh
```

Default registration (idempotent):
- `sie-llm` — **SIE self-hosted in our cluster**
  (`http://sie-gateway.sie.svc.cluster.local:8080/v1`, auth none)
- `vllm-qwen` — off by default; alternative server on the same GPU pool for
  A/B comparison (`REGISTER_VLLM=true`)
- SIE *managed* cluster (Superlinked-hosted) — commented variant in
  `providers.env.example` if an external comparison is ever needed

The in-cluster URLs work because gen-ai calls the provider from inside the
cluster. Equivalent generic script lives in gdc-nas:
`microservices/gen-ai/tools/local_provider.sh`.

## GitHub Actions

`independent-deploy.yml` (manual dispatch):
- **action**: `deploy` or `destroy`
- **environment**: which `deploy/envs/<env>` to deploy
- **gdc_nas_repository**: repo to build gen-ai from (default `janpansky/gdc-nas`)
- **gdc_nas_branch**: empty = default chart images; set = build custom gen-ai image
- **image_tag**: required when `gdc_nas_branch` is set

### Required secrets (not yet configured in this fork)

| Secret | Description |
|---|---|
| `GDCN_LICENSE_KEY` | GoodData CN license key |
| `GH_TOKEN` | GitHub PAT to checkout gdc-nas (read access to `gdc_nas_repository`) |
| `ECR_ROLE_ARN` | OIDC role ARN for ECR push (infra1 account) |
| `TERRAFORM_ROLE_ARN` | OIDC role ARN for Terraform (dev panther account) |

**OIDC caveat:** the existing AWS OIDC roles trust `Tomkess/gdc-cn-independent-deploy`.
Running this workflow from this fork requires adding
`repo:janpansky/gooddata-cn-terraform:*` to the roles' trust policies (or
creating equivalent roles). Until then, deploy locally via `deploy.sh` (SSO)
and build the image locally via `docker buildx --push`.

## Cost profile (local-inference)

Baseline with the GPU node **down** (scale-from-zero — the default state):

| Component | ~$/day |
|---|---|
| EKS control plane | 2.40 |
| Worker nodes (2-4 small dev nodes, typical) | 7–13 |
| RDS db.t4g.medium (20 GB, single-AZ) | 1.60 |
| NAT gateway (single) + ALB | 1.70 |
| **Baseline total** | **~13–19** |
| GPU g6.xlarge (L4, SIE worker) — 1 warm worker | +0.80/h (~19/day if always on) |

Guardrails in place:
- `eks_max_nodes = 6` (module default is 20 → a runaway workload could
  otherwise autoscale to ~$100+/day)
- `inference_gpu_max_nodes = 1`, GPU group starts at 0 and scales from zero —
  no pod, no GPU node, no GPU cost
- StarRocks/AI-lake off, single NAT, single-AZ RDS

Habits that keep it cheap:
- `kubectl -n inference scale deploy/vllm --replicas=0` after testing
  (GPU node gone in ~10 min)
- `./deploy/deploy.sh local-inference destroy` when not using the env for days —
  recreate is ~35 min
- Optional: set an AWS Budget alert in the panther-dev account, e.g.
  `aws budgets create-budget` with a monthly limit, to catch surprises

## State backend

State lives in the existing `gdc-cn-independent-deploy-tfstate` S3 bucket
(same AWS account, distinct key prefix `independent-deploy/<env>/`). No
interference with other users' state.
