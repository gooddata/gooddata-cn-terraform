#!/bin/bash

# Azure Terraform Destruction Script (Modular)
# WARNING: This will destroy ALL Azure infrastructure!

set -e

# Configuration
TERRAFORM_TIMEOUT=300  # 5 minutes timeout for terraform operations
KUBECTL_TIMEOUT=60     # 1 minute timeout for kubectl operations

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Timeout function for long-running commands
run_with_timeout() {
    local timeout=$1
    local command="${@:2}"
    
    log_info "Running command with ${timeout}s timeout: $command"
    
    if timeout "$timeout" bash -c "$command"; then
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_warning "Command timed out after ${timeout} seconds: $command"
            return 124
        else
            log_error "Command failed with exit code $exit_code: $command"
            return $exit_code
        fi
    fi
}

# Usage function
usage() {
    echo "Usage: $0 [SECTION]"
    echo ""
    echo "Sections (run individually or all):"
    echo "  confirm      - Show confirmation dialog"
    echo "  backup       - Create Kubernetes resource backup"
    echo "  terraform    - Run terraform destroy with auto-approve"
    echo "  kubernetes   - Clean up stuck Kubernetes resources"
    echo "  verify       - Verify destruction completion"
    echo "  cleanup      - Clean up local files"
    echo "  all          - Run all sections (default)"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run complete destruction"
    echo "  $0 terraform         # Only run terraform destroy"
    echo "  $0 kubernetes        # Only clean up stuck namespaces"
    echo ""
}

confirm_destruction() {
    local skip_confirmation="${1:-false}"
    
    echo -e "${RED}⚠️  CRITICAL WARNING ⚠️${NC}"
    echo -e "${RED}This will PERMANENTLY DELETE all Azure resources!${NC}"
    echo ""
    echo "Resources to be destroyed:"
    echo "- AKS Cluster: gooddata-cn-poc"
    echo "- nginx Ingress Controller: ingress-nginx"
    echo "- PostgreSQL Database: gooddata-cn-poc-postgresql"
    echo "- Storage Account: gooddatacnpocXXXXX"
    echo "- Virtual Network: gooddata-cn-poc-vnet"
    echo "- Resource Group: gooddata-cn-poc-rg"
    echo ""
    echo -e "${YELLOW}All data will be PERMANENTLY LOST!${NC}"
    echo ""
    
    if [ "$skip_confirmation" = "true" ]; then
        log_warning "Running in auto-approve mode - skipping manual confirmation"
        return 0
    fi
    
    read -p "Are you absolutely sure you want to continue? (type 'YES' to confirm): " confirmation
    
    if [ "$confirmation" != "YES" ]; then
        log_error "Destruction cancelled by user"
        exit 1
    fi
}

backup_data() {
    log_info "Creating backup of Kubernetes resources..."
    
    # Check if kubectl is available and cluster is accessible
    if kubectl cluster-info >/dev/null 2>&1; then
        log_info "Creating backups in ./backups/ directory..."
        mkdir -p backups
        
        # Backup organizations
        kubectl get organizations -n gooddata-cn -o yaml > backups/organizations-backup.yaml 2>/dev/null || log_warning "No organizations to backup"
        
        # Backup secrets (base64 encoded)
        kubectl get secrets -n gooddata-cn -o yaml > backups/secrets-backup.yaml 2>/dev/null || log_warning "No secrets to backup"
        
        # Backup configmaps
        kubectl get configmaps -n gooddata-cn -o yaml > backups/configmaps-backup.yaml 2>/dev/null || log_warning "No configmaps to backup"
        
        log_success "Kubernetes resources backed up to ./backups/"
    else
        log_warning "Kubernetes cluster not accessible - skipping backup"
    fi
}

cleanup_stuck_namespace() {
    local namespace=$1
    log_info "Cleaning up stuck namespace: $namespace"
    
    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log_info "Finding blocking resources in namespace: $namespace"
        
        # Find and show blocking resources
        kubectl api-resources --verbs=list --namespaced -o name | \
        xargs -n1 kubectl -n "$namespace" get --ignore-not-found 2>/dev/null | \
        grep -v "No resources found" || true
        
        # Patch services first to remove finalizers
        log_info "Patching services to remove finalizers..."
        kubectl get svc -n "$namespace" -o name 2>/dev/null | \
        xargs -I {} kubectl -n "$namespace" patch {} -p '{"metadata":{"finalizers":[]}}' --type=merge || true
        
        # Force delete remaining resources
        log_info "Force deleting remaining resources..."
        kubectl get svc -n "$namespace" -o name 2>/dev/null | \
        xargs -I {} kubectl -n "$namespace" delete {} --force --grace-period=0 || true
        
        # Remove namespace finalizers as last resort
        log_info "Removing namespace finalizers..."
        kubectl patch namespace "$namespace" -p '{"metadata":{"finalizers":[]}}' --type=merge || true
        
        log_success "Namespace $namespace cleanup completed"
    else
        log_info "Namespace $namespace not found (already deleted)"
    fi
}

cleanup_kubernetes() {
    log_info "Cleaning up Kubernetes resources..."
    
    if kubectl cluster-info >/dev/null 2>&1; then
        # Remove organizations first
        log_info "Removing organizations..."
        kubectl delete organizations --all -A --ignore-not-found=true --timeout=30s || true
        
        # Remove PVCs that might prevent deletion
        log_info "Removing PersistentVolumeClaims..."
        kubectl delete pvc --all -n gooddata-cn --ignore-not-found=true --timeout=60s
        
        # Remove test organization
        log_info "Removing test organization..."
        kubectl delete -f test-organization.yaml --ignore-not-found=true
        
        # Remove manual ingress resources
        log_info "Removing manual ingress resources..."
        kubectl delete ingress test-simple-ingress -n gooddata-cn --ignore-not-found=true
        
        log_success "Kubernetes cleanup completed"
    else
        log_warning "Kubernetes cluster not accessible - skipping K8s cleanup"
    fi
}

terraform_destroy() {
    log_info "Starting Terraform destruction with auto-approve..."
    
    # Check if terraform is initialized
    if [ ! -d ".terraform" ]; then
        log_error "Terraform not initialized. Run 'terraform init' first."
        exit 1
    fi
    
    # Show what will be destroyed (quick plan)
    log_info "Showing resources that will be destroyed..."
    if ! run_with_timeout 60 "terraform plan -destroy -var-file=terraform.tfvars -out=destroy.plan"; then
        log_warning "Terraform plan timed out or failed, proceeding with destroy anyway..."
    fi
    
    log_info "Executing terraform destroy with timeout handling..."
    
    # Attempt 1: Direct terraform destroy with timeout
    if run_with_timeout "$TERRAFORM_TIMEOUT" "terraform destroy -var-file=terraform.tfvars -auto-approve"; then
        log_success "Terraform destroy completed successfully"
        return 0
    fi
    
    # Attempt 2: Clean up stuck namespaces and retry
    log_warning "Terraform destroy timed out or failed. Cleaning up stuck resources..."
    for namespace in gooddata-cn cluster-autoscaler ingress-nginx; do
        cleanup_stuck_namespace "$namespace"
    done
    
    log_info "Retrying terraform destroy after namespace cleanup..."
    if run_with_timeout "$TERRAFORM_TIMEOUT" "terraform destroy -var-file=terraform.tfvars -auto-approve"; then
        log_success "Terraform destroy completed after namespace cleanup"
        return 0
    fi
    
    # Attempt 3: Manual Azure LoadBalancer cleanup and retry
    log_warning "Still encountering issues. Attempting manual Azure LoadBalancer cleanup..."
    NODE_RG=$(az aks show --name gooddata-cn-poc --resource-group gooddata-cn-poc-rg --query nodeResourceGroup -o tsv 2>/dev/null || true)
    if [ ! -z "$NODE_RG" ]; then
        log_info "Attempting to clean up LoadBalancer in node resource group: $NODE_RG"
        az network lb delete --name kubernetes --resource-group "$NODE_RG" --yes 2>/dev/null || true
        
        # Also try to clean up public IPs
        log_info "Cleaning up public IPs in node resource group..."
        az network public-ip list --resource-group "$NODE_RG" --query "[].name" -o tsv 2>/dev/null | \
        xargs -I {} az network public-ip delete --name {} --resource-group "$NODE_RG" --yes 2>/dev/null || true
    fi
    
    log_info "Final terraform destroy attempt..."
    if run_with_timeout "$TERRAFORM_TIMEOUT" "terraform destroy -var-file=terraform.tfvars -auto-approve"; then
        log_success "Terraform destroy completed after manual cleanup"
        return 0
    fi
    
    # All attempts failed
    log_error "All terraform destroy attempts failed. Manual cleanup may be required."
    log_warning "Common remaining resources that may need manual deletion:"
    echo "   - Public IP: gooddata-cn-poc-ingress-pip"
    echo "   - LoadBalancer in MC_gooddata-cn-poc-rg_gooddata-cn-poc_centralus"
    echo "   - Run: ./destroy.sh kubernetes  # to clean up stuck namespaces"
    echo "   - Run: az group delete --name gooddata-cn-poc-rg --yes  # to force delete resource group"
    return 1
}

verify_destruction() {
    log_info "Verifying destruction..."
    
    # Check terraform state
    state_resources=$(terraform state list 2>/dev/null | wc -l)
    if [ "$state_resources" -eq 0 ]; then
        log_success "Terraform state is clean"
    else
        log_warning "$state_resources resources still in terraform state"
    fi
    
    # Check Azure resources
    log_info "Checking for remaining Azure resources..."
    
    # Check if resource group exists
    if az group exists --name gooddata-cn-poc-rg >/dev/null 2>&1; then
        if az group exists --name gooddata-cn-poc-rg | grep -q "true"; then
            log_warning "Resource group 'gooddata-cn-poc-rg' still exists"
            
            # List remaining resources
            remaining_resources=$(az resource list --resource-group gooddata-cn-poc-rg --query "length(@)" 2>/dev/null || echo "0")
            if [ "$remaining_resources" -gt 0 ]; then
                log_warning "$remaining_resources resources still exist in resource group"
                az resource list --resource-group gooddata-cn-poc-rg --output table
            fi
        else
            log_success "Resource group 'gooddata-cn-poc-rg' successfully deleted"
        fi
    else
        log_success "Resource group verification completed"
    fi
}

cleanup_local_files() {
    log_info "Cleaning up local files..."
    
    # Remove temporary files
    rm -f gooddata-selfsigned.crt gooddata-selfsigned.key
    rm -f auth-agic-ingress.yaml org-agic-ingress.yaml test-simple-ingress.yaml
    rm -f destroy.plan
    
    # Remove terraform state files (auto-approve for consistency)
    log_info "Removing Terraform state files..."
    rm -f terraform.tfstate*
    rm -f .terraform.lock.hcl
    log_success "Terraform state files removed"
    
    log_success "Local cleanup completed"
}

run_section() {
    local section=$1
    
    case "$section" in
        "confirm")
            confirm_destruction
            ;;
        "backup")
            backup_data
            ;;
        "terraform")
            log_warning "Running terraform destroy section - this will delete Azure infrastructure!"
            confirm_destruction
            terraform_destroy
            ;;
        "kubernetes")
            log_info "Running Kubernetes cleanup section - this will clean stuck namespaces"
            cleanup_kubernetes
            ;;
        "verify")
            verify_destruction
            ;;
        "cleanup")
            cleanup_local_files
            ;;
        "all")
            run_all_sections
            ;;
        *)
            log_error "Unknown section: $section"
            usage
            exit 1
            ;;
    esac
}

run_all_sections() {
    log_info "Azure Terraform Destruction Script Started (Auto-Approve Mode)"
    echo ""
    
    # Step 1: Confirmation
    confirm_destruction
    
    # Step 2: Backup (auto-create)
    log_info "Creating backup automatically..."
    backup_data
    
    # Step 3: Terraform destroy
    terraform_destroy
    
    # Step 4: Kubernetes cleanup
    cleanup_kubernetes
    
    # Step 5: Verification
    verify_destruction
    
    # Step 6: Local cleanup
    cleanup_local_files
    
    echo ""
    log_success "🎉 Destruction completed successfully!"
    echo ""
    log_info "Next steps:"
    echo "1. Monitor Azure billing for cost reductions"
    echo "2. Check Azure Activity Log for any errors"
    echo "3. Backups are available in ./backups/ directory"
    echo ""
    log_warning "Remember: All data has been permanently deleted!"
}

# Check prerequisites
check_prerequisites() {
    local errors=0
    
    if ! command -v terraform >/dev/null 2>&1; then
        log_error "Terraform is not installed or not in PATH"
        errors=1
    fi

    if ! command -v az >/dev/null 2>&1; then
        log_error "Azure CLI is not installed or not in PATH"
        errors=1
    fi
    
    if ! command -v timeout >/dev/null 2>&1; then
        log_error "timeout command is not available (install coreutils)"
        errors=1
    fi

    # Check Azure authentication (only if az is available)
    if command -v az >/dev/null 2>&1; then
        if ! az account show >/dev/null 2>&1; then
            log_error "Not authenticated with Azure CLI. Run 'az login' first."
            errors=1
        fi
    fi
    
    if [ $errors -eq 1 ]; then
        exit 1
    fi
}

# Main execution
main() {
    local section="${1:-all}"
    
    # Handle help/usage
    if [ "$section" = "-h" ] || [ "$section" = "--help" ] || [ "$section" = "help" ]; then
        usage
        exit 0
    fi
    
    # Check prerequisites before running
    check_prerequisites
    
    # Run the specified section
    log_info "Running section: $section"
    run_section "$section"
}

# Execute main function with all arguments
main "$@"
