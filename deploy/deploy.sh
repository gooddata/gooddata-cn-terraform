#!/usr/bin/env bash
set -euo pipefail

###
# Independent GoodData CN deployment helper (multi-environment)
#
# Lives next to the terraform module it deploys (../aws) — no external clone
# needed. Environments are defined in deploy/envs/<env>/settings.tfvars.
#
# Usage:
#   ./deploy.sh <env> init      - Initialize Terraform for <env> (run once, or when switching envs)
#   ./deploy.sh <env> apply     - Deploy / update the environment (~35 min on first run)
#   ./deploy.sh <env> destroy   - Tear down all resources of <env>
#   ./deploy.sh <env> status    - Show Terraform outputs (URLs, cluster name)
#   ./deploy.sh <env> kubectl   - Configure kubectl for the deployed cluster
#
# Each environment has its own Terraform state in S3; switching environments
# requires re-running `init` (the script guards against applying one env
# while initialized for another).
#
# License key: set GDCN_LICENSE_KEY in the environment, or fill in
# gdcn_license_key in the env's settings.tfvars (do NOT commit a filled-in key).
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/aws"
AWS_PROFILE="aws-panther-dev"
COREUTILS_PATH="/opt/homebrew/opt/coreutils/libexec/gnubin"
ENV_MARKER="$TF_DIR/.independent-deploy-current-env"

export AWS_PROFILE
export PATH="$COREUTILS_PATH:$PATH"

ENV_NAME="${1:-}"
cmd="${2:-help}"

usage() {
    echo "Usage: ./deploy.sh <env> [init|apply|destroy|status|kubectl]"
    echo ""
    echo "Available environments:"
    for d in "$SCRIPT_DIR"/envs/*/; do
        echo "  - $(basename "$d")"
    done
    echo ""
    echo "  init      Initialize Terraform for <env> (run once, or when switching envs)"
    echo "  apply     Deploy / update the environment (~35 min on first run)"
    echo "  destroy   Tear down all resources"
    echo "  status    Show Terraform outputs (URLs, cluster name)"
    echo "  kubectl   Configure kubectl for the deployed cluster"
}

if [[ -z "$ENV_NAME" || "$ENV_NAME" == "help" ]]; then
    usage
    exit 0
fi

SETTINGS="$SCRIPT_DIR/envs/$ENV_NAME/settings.tfvars"
# Generated var-file with secrets injected — matches the repo's *.tfvars
# gitignore, never committed.
WORK_TFVARS="$TF_DIR/.independent-deploy.$ENV_NAME.tfvars"
STATE_KEY="independent-deploy/$ENV_NAME/terraform.tfstate"

check_env() {
    if [[ ! -f "$SETTINGS" ]]; then
        echo "ERROR: unknown environment '$ENV_NAME' — $SETTINGS not found"
        echo ""
        usage
        exit 1
    fi
}

check_sso() {
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
        echo ">> SSO session expired. Refreshing..."
        aws sso login --profile "$AWS_PROFILE"
    fi
    # Terraform's AWS SDK chokes on legacy-format SSO profiles even when the
    # CLI session is valid ("failed to refresh cached credentials"). Export
    # static credentials and bypass the profile in the provider instead.
    eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"
    unset AWS_PROFILE
    TF_PROFILE_OVERRIDE=(-var aws_profile_name=)
}

# Guard: refuse to touch state if the working dir is initialized for another env.
check_initialized_env() {
    if [[ ! -f "$ENV_MARKER" ]]; then
        echo "ERROR: Terraform not initialized for any environment."
        echo "       Run: ./deploy.sh $ENV_NAME init"
        exit 1
    fi
    current="$(cat "$ENV_MARKER")"
    if [[ "$current" != "$ENV_NAME" ]]; then
        echo "ERROR: Terraform is initialized for '$current', not '$ENV_NAME'."
        echo "       Run: ./deploy.sh $ENV_NAME init"
        exit 1
    fi
}

write_work_tfvars() {
    cp "$SETTINGS" "$WORK_TFVARS"
    # Inject license key from env var if provided (replaces the empty value in
    # place — appending a second assignment would be a duplicate-attribute error)
    if [[ -n "${GDCN_LICENSE_KEY:-}" ]]; then
        sed -i.bak -E "s|^(gdcn_license_key[[:space:]]*=[[:space:]]*)\"\"|\1\"$GDCN_LICENSE_KEY\"|" "$WORK_TFVARS"
        rm -f "$WORK_TFVARS.bak"
    fi
    if grep -qE '^gdcn_license_key[[:space:]]*=[[:space:]]*""' "$WORK_TFVARS"; then
        echo "ERROR: gdcn_license_key is empty in $SETTINGS and GDCN_LICENSE_KEY is not set"
        exit 1
    fi
}

case "$cmd" in
    init)
        check_env
        check_sso
        echo ">> Initializing Terraform for '$ENV_NAME' (state: $STATE_KEY)..."
        cd "$TF_DIR"
        terraform init -reconfigure -backend-config="key=$STATE_KEY"
        echo "$ENV_NAME" > "$ENV_MARKER"
        ;;

    apply)
        check_env
        check_sso
        check_initialized_env
        write_work_tfvars
        echo ">> Running terraform apply for '$ENV_NAME' (~35 min on first run)..."
        cd "$TF_DIR"
        terraform apply -var-file="$WORK_TFVARS" "${TF_PROFILE_OVERRIDE[@]}" -auto-approve
        echo ""
        echo ">> Configuring kubectl..."
        "$REPO_ROOT/scripts/configure-kubectl.sh"
        echo ""
        echo ">> Deployment complete!"
        # org_domains is a list output, so `-raw` (string-only) errors; use -json + jq.
        # Guarded so this purely informational step never fails an otherwise-successful apply.
        terraform output -json org_domains 2>/dev/null | jq -r '.[]?' | while read -r domain; do
            echo "   https://$domain"
        done || true
        ;;

    destroy)
        check_env
        check_sso
        check_initialized_env
        write_work_tfvars
        echo ">> Running terraform destroy for '$ENV_NAME'..."
        cd "$TF_DIR"
        terraform destroy -var-file="$WORK_TFVARS" "${TF_PROFILE_OVERRIDE[@]}" -auto-approve
        echo ">> All resources of '$ENV_NAME' destroyed."
        ;;

    status)
        check_env
        check_sso
        check_initialized_env
        cd "$TF_DIR"
        terraform output
        ;;

    kubectl)
        check_env
        check_sso
        check_initialized_env
        AWS_PROFILE="aws-panther-dev" "$REPO_ROOT/scripts/configure-kubectl.sh"
        ;;

    help|*)
        usage
        ;;
esac
