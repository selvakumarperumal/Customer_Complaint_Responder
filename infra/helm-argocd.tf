resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = "argocd"

  create_namespace = true
  cleanup_on_fail  = true
  replace          = true
  force_update     = true
  timeout          = 600
  wait             = false

  # ArgoCD is a system-level tool — it needs to tolerate the
  # CriticalAddonsOnly taint to schedule on the system node group.
  # Without this, all ArgoCD pods (including pre-install hook Jobs)
  # stay Pending → "0/2 nodes available: untolerated taint(s)"
  values = [yamlencode({
    global = {
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
      ]
      nodeSelector = {
        role = "system"
      }
    }
    # Ensure CRDs are deleted on terraform destroy — by default
    # ArgoCD marks them with helm.sh/resource-policy: keep
    crds = {
      keep = false
    }
  })]

  depends_on = [module.eks]

}

# For future reference if using a private GitHub repository for ArgoCD GitOps:
# resource "kubernetes_secret" "github_repo_creds" {
#   metadata {
#     name      = "github-repo-creds"
#     namespace = "argocd"
#     labels = {
#       "argocd.argoproj.io/secret-type" = "repository"
#     }
#   }
#   data = {
#     type     = "git"
#     url      = "https://github.com/yourname/your-gitops-repo.git"
#     username = "yourname"
#     password = var.github_pat
#   }
#   depends_on = [module.eks, helm_release.argocd]
# }
