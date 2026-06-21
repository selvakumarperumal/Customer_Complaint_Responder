# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   terraform plan  -var-file=environments/prod.tfvars
#   terraform apply -var-file=environments/prod.tfvars
#
# Never commit google_api_key to source control.
# Pass it via: export TF_VAR_google_api_key="AIza..."
# ─────────────────────────────────────────────────────────────────────────────

aws_region   = "ap-south-1"
cluster_name = "ccr-prod"

tags = {
  Environment = "prod"
  Project     = "customer-complaint-responder"
  ManagedBy   = "terraform"
}

# VPC
vpc_cidr             = "10.1.0.0/16"
public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
private_subnet_cidrs = ["10.1.4.0/24", "10.1.5.0/24", "10.1.6.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
enable_nat_gateway   = true
single_nat_gateway   = false  # one NAT per AZ for HA in prod

# EKS
kubernetes_version      = "1.32"
service_ipv4_cidr_block = "172.20.0.0/16"
endpoint_public_access  = true
endpoint_private_access = true
public_access_cidrs     = ["0.0.0.0/0"]  # restrict to your office CIDRs in prod
enable_pod_identity     = true

core_dns_version   = ""
kube_proxy_version = ""
vpc_cni_version    = ""

# Node groups — subnet_ids are injected automatically from the VPC module
node_groups = {
  general = {
    instance_types = ["t3.large"]
    desired_size   = 3
    min_size       = 2
    max_size       = 10
    capacity_type  = "ON_DEMAND"
    labels = {
      role = "general"
    }
  }
  spot = {
    instance_types = ["t3.large", "t3a.large", "m5.large"]
    desired_size   = 2
    min_size       = 0
    max_size       = 10
    capacity_type  = "SPOT"
    labels = {
      role = "spot"
    }
    taints = [
      {
        key    = "spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    ]
  }
}

# Backend
backend_namespace       = "backend"
backend_service_account = "backend"

# google_api_key — do NOT put here; use: export TF_VAR_google_api_key="AIza..."
