module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  cluster_name                    = module.eks.cluster_name
  create_pod_identity_association = true
  create_node_iam_role            = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${module.eks.cluster_name}-karpenter-node-role"
}
