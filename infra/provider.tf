terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  # Uncomment to use S3 remote state backend:
  # backend "s3" {
  #   bucket         = "<your-tfstate-bucket>"
  #   key            = "ccr/terraform.tfstate"
  #   region         = "<your-region>"
  #   encrypt        = true
  #   dynamodb_table = "<your-lock-table>"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Kubernetes provider
# Uses `aws eks get-token` via the exec plugin so tokens are always fresh.
# The exec command runs at apply time (not init time), so it works even on
# the first apply when the cluster is being created — Terraform creates EKS
# first (due to depends_on on the kubernetes resources), then connects.
# ─────────────────────────────────────────────────────────────────────────────
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}
