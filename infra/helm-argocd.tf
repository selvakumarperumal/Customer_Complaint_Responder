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
