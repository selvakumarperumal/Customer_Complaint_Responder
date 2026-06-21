# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   terraform plan  -var-file=environments/dev.tfvars
#   terraform apply -var-file=environments/dev.tfvars
#
# Never commit google_api_key to source control.
# Pass it via: export TF_VAR_google_api_key="AIza..."
# ─────────────────────────────────────────────────────────────────────────────

aws_region   = "ap-south-1"
cluster_name = "ccr-dev"

tags = {
  Environment = "dev"
  Project     = "customer-complaint-responder"
  ManagedBy   = "terraform"
}

# VPC
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
enable_nat_gateway   = true
single_nat_gateway   = true  # single NAT to reduce cost in dev

# EKS
kubernetes_version      = "1.32"
service_ipv4_cidr_block = "172.20.0.0/16"
endpoint_public_access  = true
endpoint_private_access = true
public_access_cidrs     = ["0.0.0.0/0"]
enable_pod_identity     = true

core_dns_version   = ""
kube_proxy_version = ""
vpc_cni_version    = ""

# Node groups — subnet_ids are injected automatically from the VPC module
node_groups = {
  general = {
    instance_types = ["t3.medium"]
    desired_size   = 2
    min_size       = 1
    max_size       = 4
    capacity_type  = "ON_DEMAND"
    labels = {
      role = "general"
    }
  }
}

# Backend
backend_namespace       = "default"
backend_service_account = "backend"

# google_api_key — do NOT put here; use: export TF_VAR_google_api_key="AIza..."
