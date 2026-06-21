#!/usr/bin/env bash
# scripts/build-push.sh
#
# Builds the backend Docker image and pushes it to ECR.
# Reads ECR URL and region directly from `terraform output` — no manual copy-paste.
#
# Usage:
#   cd <repo-root>
#   IMAGE_TAG=v1.2.0 ./scripts/build-push.sh
#
# Environment variables:
#   IMAGE_TAG   Tag to apply to the image (default: git short SHA)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"
BACKEND_DIR="$REPO_ROOT/backend"

# Default tag: git short SHA so every build is traceable
DEFAULT_TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "latest")"
TAG="${IMAGE_TAG:-$DEFAULT_TAG}"

# ─────────────────────────────────────────────────────────────────────────────
# Read Terraform outputs — no need to export or copy anything manually
# ─────────────────────────────────────────────────────────────────────────────
echo "Reading Terraform outputs from $INFRA_DIR ..."
cd "$INFRA_DIR"

ECR_URL=$(terraform output -raw ecr_repository_url)
AWS_REGION=$(terraform output -raw aws_region)

echo ""
echo "  ECR repository : $ECR_URL"
echo "  AWS region     : $AWS_REGION"
echo "  Image tag      : $TAG"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Authenticate Docker with ECR
# docker login must receive the registry hostname only (no path), e.g.:
#   123456789.dkr.ecr.ap-south-1.amazonaws.com
# NOT the full repo URL (.../ccr-dev/backend). ECR tokens are per-registry.
# ─────────────────────────────────────────────────────────────────────────────
ECR_REGISTRY=$(echo "$ECR_URL" | cut -d'/' -f1)
echo "Authenticating Docker with ECR ($ECR_REGISTRY) ..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────
echo "Building image ..."
docker build \
  --tag "$ECR_URL:$TAG" \
  --tag "$ECR_URL:latest" \
  "$BACKEND_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Push
# ─────────────────────────────────────────────────────────────────────────────
echo "Pushing to ECR ..."
docker push "$ECR_URL:$TAG"
docker push "$ECR_URL:latest"

echo ""
echo "Done — image pushed:"
echo "  $ECR_URL:$TAG"
echo "  $ECR_URL:latest"
echo ""
echo "Next step: deploy with IMAGE_TAG=$TAG ./scripts/deploy.sh"
