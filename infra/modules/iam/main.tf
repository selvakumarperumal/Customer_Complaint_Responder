terraform {
    required_version = ">= 1.15.0"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 6.0"
        }
    }
}

resource "aws_iam_role" "eks_cluster_role" {
    name = "${var.cluster_name}-eks-cluster-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Principal = {
                    Service = "eks.amazonaws.com"
                }
                Action = "sts:AssumeRole"
            }
        ]
    })
    tags = merge(
        var.tags,
        {
            Name = "${var.cluster_name}-eks-cluster-role"
        }
    )
}

resource "aws_iam_role_policy_attachment" "eks_cluster_role_attachment" {
    role       = aws_iam_role.eks_cluster_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_vpc_resource_controller_attachment" {
    role       = aws_iam_role.eks_cluster_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

resource "aws_iam_role" "eks_node_group_role" {
    name = "${var.cluster_name}-eks-node-group-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Principal = {
                    Service = "ec2.amazonaws.com"
                }
                Action = "sts:AssumeRole"
            }
        ]
    })
    tags = merge(
        var.tags,
        {
            Name = "${var.cluster_name}-eks-node-group-role"
        }
    )
}

resource "aws_iam_role_policy_attachment" "eks_node_group_role_attachment" {
    role       = aws_iam_role.eks_node_group_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy_attachment" {
    role       = aws_iam_role.eks_node_group_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  
}

resource "aws_iam_role_policy_attachment" "eks_registry_read_only_attachment" {
    role       = aws_iam_role.eks_node_group_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}