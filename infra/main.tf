# ─────────────────────────────────────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  name_prefix          = var.cluster_name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway

  # Required EKS subnet tags for the AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }

  tags = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM roles for EKS cluster and node groups
# ─────────────────────────────────────────────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  cluster_name = var.cluster_name
  tags         = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS cluster
# ─────────────────────────────────────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  cluster_name            = var.cluster_name
  kubernetes_version      = var.kubernetes_version
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
  private_subnet_ids      = module.vpc.private_subnet_ids
  service_ipv4_cidr_block = var.service_ipv4_cidr_block
  cluster_role_arn        = module.iam.cluster_role_arn
  node_group_role_arn     = module.iam.node_group_role_arn
  endpoint_public_access  = var.endpoint_public_access
  endpoint_private_access = var.endpoint_private_access
  public_access_cidrs     = var.public_access_cidrs
  node_groups             = var.node_groups
  core_dns_version        = var.core_dns_version
  kube_proxy_version      = var.kube_proxy_version
  vpc_cni_version         = var.vpc_cni_version
  vpc_cni_role_arn        = ""
  enable_irsa             = var.enable_irsa
  tags                    = var.tags

  depends_on = [module.iam]
}

# ─────────────────────────────────────────────────────────────────────────────
# Secrets Manager — Google/Gemini API key + IRSA role for backend pod
# ─────────────────────────────────────────────────────────────────────────────
module "secret_manager" {
  source = "./modules/secret_manager"

  cluster_name         = var.cluster_name
  secret_name          = "${var.cluster_name}/google-api-key"
  secret_value         = var.google_api_key
  enable_irsa          = var.enable_irsa
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url
  namespace            = var.backend_namespace
  service_account_name = var.backend_service_account
  tags                 = var.tags

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR — image repository for the backend container
# ─────────────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "./modules/ecr"

  cluster_name    = var.cluster_name
  repository_name = "${var.cluster_name}/backend"
  tags            = var.tags
}

# Attach the ECR pull policy to the backend IRSA role created by secret_manager.
# This allows the backend service account to authenticate with ECR in addition
# to reading the API key secret — both permissions land on a single IRSA role.
resource "aws_iam_role_policy_attachment" "backend_ecr_pull" {
  count = var.enable_irsa ? 1 : 0

  role       = module.secret_manager.backend_irsa_role_name
  policy_arn = module.ecr.ecr_pull_policy_arn

  depends_on = [module.secret_manager, module.ecr]
}
