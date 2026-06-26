module "eks" {
  source = "terraform-aws-modules/eks/aws"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    system = {
      instance_types = ["m5.large"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1

      labels = {
        role = "system"
      }

      # Lock the door — only pods with a matching toleration can land here
      taints = {
        critical_addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  addons = {
    # DaemonSets — kube-proxy, vpc-cni, eks-pod-identity-agent already ship
    # with a built-in wildcard toleration (operator: Exists, no key), so
    # they need no patching here. They'll run on the system node group
    # regardless of the taint above.
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}

    # CoreDNS is a Deployment, not a DaemonSet — it ships with NO
    # toleration by default, so without this patch it would get stuck
    # Pending on a tainted-only cluster.
    coredns = {
      configuration_values = jsonencode({
        tolerations = [
          {
            key      = "CriticalAddonsOnly"
            operator = "Exists"
          }
        ]
        nodeSelector = {
          role = "system"
        }
      })
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

}
