module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.24.0" # Pin version — explicit pannunga

  cluster_name = module.eks.cluster_name

  # ── Controller side: Pod Identity for the Karpenter controller pod ──
  create_pod_identity_association = true
  namespace                       = "kube-system" # explicit, matches your ArgoCD destination
  service_account                 = "karpenter"   # explicit, matches your ArgoCD Helm value

  # ── Node side: role attached to EC2 instances Karpenter launches ──
  create_node_iam_role          = true
  node_iam_role_name            = "karpenter-node-role"
  node_iam_role_use_name_prefix = false

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # ── Instance profile: REQUIRED for EC2-launched nodes to use the node role ──
  create_instance_profile = true

  # ── Controller IAM policy size workaround ──
  enable_inline_policy = true
}
