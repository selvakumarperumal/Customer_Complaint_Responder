terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

resource "aws_kms_key" "eks_kms_key" {
  description             = "KMS key for EKS secrets encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.cluster_name}-kms-key" })
}

resource "aws_kms_alias" "eks_kms_key_alias" {
  name          = "alias/eks/${var.cluster_name}"
  target_key_id = aws_kms_key.eks_kms_key.key_id
}

resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-sg-"
  description = "Security group for EKS cluster"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "node" {
  name_prefix = "${var.cluster_name}-node-sg-"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-node-sg"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "node_to_cluster" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.node.id
  description              = "Allow Node to communicate with Cluster API"
}

resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.cluster.id
  description              = "Allow Cluster control plane to communicate with Nodes"
}

resource "aws_security_group_rule" "node_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  security_group_id = aws_security_group.node.id
  self              = true
  description       = "Allow Node to communicate with itself"
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.service_ipv4_cidr_block
    ip_family         = "ipv4"
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_kms_key.arn
    }
    resources = ["secrets"]
  }

  # No control-plane logging
  enabled_cluster_log_types = []

  tags = merge(var.tags, { Name = var.cluster_name })
}

data "tls_certificate" "cluster" {
  count = var.enable_irsa ? 1 : 0
  url   = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  count           = var.enable_irsa ? 1 : 0
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster[0].certificates[0].sha1_fingerprint]

  tags = merge(var.tags, { Name = "${var.cluster_name}-oidc-provider" })
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = var.core_dns_version != "" ? var.core_dns_version : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]

  tags = merge(var.tags, { Name = "${var.cluster_name}-coredns" })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = var.kube_proxy_version != "" ? var.kube_proxy_version : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(var.tags, { Name = "${var.cluster_name}-kube-proxy" })
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = var.vpc_cni_version != "" ? var.vpc_cni_version : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  service_account_role_arn = var.vpc_cni_role_arn != "" ? var.vpc_cni_role_arn : var.node_group_role_arn

  tags = merge(var.tags, { Name = "${var.cluster_name}-vpc-cni" })
}

resource "aws_launch_template" "eks_node_launch_template" {
  for_each = var.node_groups

  name_prefix            = "${var.cluster_name}-${each.key}-"
  description            = "Launch template for EKS node group ${each.key}"
  update_default_version = true
  ebs_optimized          = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  vpc_security_group_ids = [aws_security_group.node.id]

  # Detailed monitoring disabled — use basic CloudWatch metrics only
  monitoring {
    enabled = false
  }

  private_dns_name_options {
    hostname_type = "resource-name"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      { Name = "${var.cluster_name}-${each.key}-node" }
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      var.tags,
      { Name = "${var.cluster_name}-${each.key}-volume" }
    )
  }
}

resource "aws_eks_node_group" "main" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-${each.key}-node"
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  labels         = each.value.labels

  dynamic "taint" {
    for_each = coalesce(each.value.taints, [])
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  launch_template {
    id      = aws_launch_template.eks_node_launch_template[each.key].id
    version = aws_launch_template.eks_node_launch_template[each.key].latest_version
  }

  tags = merge(
    var.tags,
    lookup(each.value, "tags", {})
  )

  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
