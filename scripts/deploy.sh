#!/usr/bin/env bash
# scripts/deploy.sh
#
# Deploys the backend Helm chart to EKS.
# Reads ALL values from `terraform output` — no manual exports or copy-paste needed.
#
# ─────────────────────────────────────────────────────────────────────────────
# Design: ServiceAccount is created by Terraform, not Helm
# ─────────────────────────────────────────────────────────────────────────────
#   terraform apply creates:
#     • AWS resources (VPC, EKS, ECR, Secrets Manager, IRSA role)
#     • Kubernetes ServiceAccount (infra/addons.tf) — annotated with the IRSA
#       role ARN so EKS injects OIDC tokens automatically
#
#   This script (helm upgrade) creates the app workload objects only:
#     • Deployment, Service, ESO SecretStore, ExternalSecret, HPA, Ingress
#
#   helm/values.yaml has serviceAccount.create: false so Helm references the
#   pre-existing SA by name and never touches its annotations.
# ─────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   cd <repo-root>
#   IMAGE_TAG=v1.2.0 ./scripts/deploy.sh
#
# Environment variables:
#   IMAGE_TAG    Tag of the image to deploy (default: latest)
#   NAMESPACE    Kubernetes namespace (default: default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"
HELM_DIR="$REPO_ROOT/helm"

TAG="${IMAGE_TAG:-latest}"
NAMESPACE="${NAMESPACE:-default}"

# ─────────────────────────────────────────────────────────────────────────────
# Read ALL required values from Terraform — nothing needs to be exported manually
# ─────────────────────────────────────────────────────────────────────────────
echo "Reading Terraform outputs from $INFRA_DIR ..."
cd "$INFRA_DIR"

CLUSTER=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region)
ECR_URL=$(terraform output -raw ecr_repository_url)
# Note: IRSA role ARN is NOT needed here — the ServiceAccount was already created
# by Terraform (infra/addons.tf) with the eks.amazonaws.com/role-arn annotation
# already set. Helm just references the existing SA (serviceAccount.create: false).

echo ""
echo "  Cluster        : $CLUSTER"
echo "  Region         : $AWS_REGION"
echo "  ECR URL        : $ECR_URL"
echo "  Image tag      : $TAG"
echo "  Namespace      : $NAMESPACE"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Update kubeconfig — sets kubectl context to this cluster
# ─────────────────────────────────────────────────────────────────────────────
echo "Updating kubeconfig ..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"

# ─────────────────────────────────────────────────────────────────────────────
# Deploy
# ─────────────────────────────────────────────────────────────────────────────
echo "Deploying Helm chart ..."
helm upgrade --install ccr "$HELM_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set clusterName="$CLUSTER" \
  --set awsRegion="$AWS_REGION" \
  --set image.repository="$ECR_URL" \
  --set image.tag="$TAG" \
  --wait

echo ""
echo "Deploy complete. Verifying ..."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Quick health check
# ─────────────────────────────────────────────────────────────────────────────
echo "--- ESO sync status (look for READY=True) ---"
kubectl get externalsecret -n "$NAMESPACE" 2>/dev/null || true

echo ""
echo "--- Pods ---"
kubectl get pods -l app.kubernetes.io/name=customer-complaint-responder \
  -n "$NAMESPACE"

echo ""
echo "To stream logs:"
echo "  kubectl logs -l app.kubernetes.io/name=customer-complaint-responder -n $NAMESPACE -f"
