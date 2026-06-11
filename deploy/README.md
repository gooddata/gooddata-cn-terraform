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

## Inference strategy

**Everything runs in our cluster.** Open-weights **Qwen3.6-27B** (the
benchmark model, ≈GPT-5.2 quality) downloaded from Hugging Face and served by
**vLLM** on our GPU pool (`g6e.xlarge`, 1x L40S 48 GB, FP8 quantization).
Nothing flows through Superlinked or any external inference service — this is
the data-sovereignty story end to end.

```bash
./deploy/deploy.sh local-inference kubectl
kubectl apply -f deploy/k8s/vllm-qwen.yaml
# first start: ~55 GB weights download + FP8 quantization — 20-30 min
kubectl -n inference get pods -w
```

In-cluster endpoint: `http://vllm.inference.svc.cluster.local:8000/v1` —
function calling enabled (`--enable-auto-tool-choice`) → the full agentic
flow works through the LOCAL provider. Scale to zero when idle:
`kubectl -n inference scale deploy/vllm --replicas=0` (GPU node gone in
~10 min; next start re-downloads the weights).

**Optional A/B comparison: Superlinked SIE managed cluster** (their GPUs,
`REGISTER_SIE=true` in providers.env). Caveats: 25+ min cold starts returning
HTTP 202 that the adapter doesn't handle (warm with curl first), deployed
config rejects `tools` (text-only fallback), plain HTTP.

## Registering LLM providers (vLLM + SIE side by side)

After deployment, register both inference backends as LOCAL providers for
A/B testing — the in-cluster vLLM and the Superlinked SIE managed cluster:

```bash
cp deploy/providers/providers.env.example deploy/providers/providers.env
# fill in TIGER_API_TOKEN (org token) and SIE_API_KEY (SL-... token)
./deploy/providers/register-providers.sh
```

Registers (idempotently):
- `vllm-qwen` — in-cluster vLLM, `Qwen/Qwen3.6-27B` (FP8), no external dependency
- `sie-llm` — Superlinked managed cluster (us-east-2), `Qwen/Qwen3.6-27B`;
  expect long cold starts when their worker pool is down (25+ min measured)

Toggle either with `REGISTER_VLLM`/`REGISTER_SIE` in `providers.env`. The
in-cluster URL works because gen-ai calls the provider from inside the
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
| GPU g6e.xlarge (L40S) — **only while vLLM runs** | +1.86/h (~+15 per workday) |

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
