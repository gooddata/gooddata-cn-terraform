terraform {
  backend "s3" {
    bucket  = "gdc-cn-independent-deploy-tfstate"
    region  = "us-east-1"
    encrypt = true
    # `key` is supplied per environment via `terraform init -backend-config`:
    #   independent-deploy/<env>/terraform.tfstate
    # See deploy/deploy.sh and .github/workflows/independent-deploy.yml.
  }
}
