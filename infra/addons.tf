# ==============================================================================
# KUBERNETES PLATFORM OBJECTS + AWS POD IDENTITY ASSOCIATIONS
# ==============================================================================
# This file creates Kubernetes objects and AWS Pod Identity bindings that must
# exist before the app Helm chart is deployed.
#
#   Terraform  →  AWS resources + platform K8s objects (this file)
#   Helm       →  app workload objects (Deployment, Service, ESO resources, …)
#
# How Pod Identity works (replaces IRSA):
#   IRSA (old):  K8s SA has `eks.amazonaws.com/role-arn` annotation.
#                EKS exchanges an OIDC JWT for STS credentials.
#   Pod Identity (new):
#                `aws_eks_pod_identity_association` binds cluster+namespace+SA
#                to an IAM role in the AWS control plane — no annotation on SA.
#                The EKS Pod Identity Agent DaemonSet intercepts credential
#                requests and returns short-lived credentials scoped to the role.
#
# Order of creation (enforced by depends_on):
#   1. EKS cluster + Pod Identity Agent addon  (module.eks)
#   2. IAM role                                (module.secret_manager)
#   3. K8s namespace + ServiceAccount          (this file)
#   4. Pod Identity associations               (this file)  ← two: backend + ESO
#   5. Helm chart                              (scripts/deploy.sh)
#
# Two associations:
#   backend  →  backend pod can call AWS directly if needed (ECR pull, etc.)
#   eso      →  ESO controller uses this role to sync secrets from Secrets Manager
#               SecretStore in helm/templates/secretstore.yaml uses no explicit
#               auth — ESO picks up credentials via the Pod Identity Agent.
# ==============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Backend namespace  (skip if using "default" — it always exists)
# ─────────────────────────────────────────────────────────────────────────────
resource "kubernetes_namespace_v1" "backend" {
  count = (var.enable_pod_identity && var.backend_namespace != "default") ? 1 : 0

  metadata {
    name = var.backend_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# Backend ServiceAccount
#
# With Pod Identity there is NO eks.amazonaws.com/role-arn annotation.
# The IAM binding lives entirely in aws_eks_pod_identity_association below.
# ─────────────────────────────────────────────────────────────────────────────
resource "kubernetes_service_account_v1" "backend" {
  count = var.enable_pod_identity ? 1 : 0

  metadata {
    name      = var.backend_service_account
    namespace = var.backend_namespace
    labels = {
      "app.kubernetes.io/name"       = var.backend_service_account
      "app.kubernetes.io/managed-by" = "terraform"
    }
    # No annotations — Pod Identity does not use the eks.amazonaws.com/role-arn
    # annotation. The association resource below handles the binding.
  }

  automount_service_account_token = true

  depends_on = [
    module.eks,
    kubernetes_namespace_v1.backend,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Pod Identity Association — backend ServiceAccount
#
# Binds the backend SA (namespace + name) to the IAM role.
# Only pods running with this SA in this namespace + cluster can assume the role.
# AWS enforces the exact match — no trust-policy conditions to misconfigure.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_eks_pod_identity_association" "backend" {
  count = var.enable_pod_identity ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = var.backend_namespace
  service_account = var.backend_service_account
  role_arn        = module.secret_manager.backend_role_arn

  tags = merge(var.tags, { Name = "${module.eks.cluster_name}-backend-pod-identity" })

  depends_on = [
    module.eks,
    module.secret_manager,
    kubernetes_service_account_v1.backend,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Pod Identity Association — External Secrets Operator controller SA
#
# ESO's controller pod is the one that actually calls secretsmanager:GetSecretValue.
# Giving ESO's own SA a Pod Identity association means the SecretStore in
# helm/templates/secretstore.yaml can omit the auth block entirely — ESO will
# pick up credentials from the Pod Identity Agent automatically.
#
# Default ESO SA: namespace=external-secrets, name=external-secrets
# (matches the official Helm chart defaults; override via var.eso_*)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_eks_pod_identity_association" "eso" {
  count = var.enable_pod_identity ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = var.eso_namespace
  service_account = var.eso_service_account
  role_arn        = module.secret_manager.backend_role_arn

  tags = merge(var.tags, { Name = "${module.eks.cluster_name}-eso-pod-identity" })

  depends_on = [
    module.eks,
    module.secret_manager,
  ]
}
