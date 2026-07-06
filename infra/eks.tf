module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # Cost optimization: t3.medium ($0.042/hr) vs m5.large ($0.096/hr)
  # System node runs ArgoCD, CoreDNS, Karpenter, External Secrets — 2 vCPU / 4 GiB is plenty

  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2

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
    # before_compute = true ensures these addons are installed BEFORE
    # the node group is created. Without this, the module creates addons
    # AFTER node groups (depends_on), but nodes need VPC CNI to get
    # networking and become Ready — causing a deadlock:
    #   node group waits for Ready → needs VPC CNI → waits for node group
    vpc-cni = {
      before_compute = true
    }

    kube-proxy = {}
    coredns    = {}

    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

}
