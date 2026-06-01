output "cluster_role_name" {
    value = aws_iam_role.eks_cluster_role.name
}

output "node_group_role_name" {
    value = aws_iam_role.eks_node_group_role.name
}

output "cluster_role_arn" {
    value = aws_iam_role.eks_cluster_role.arn
}

output "node_group_role_arn" {
    value = aws_iam_role.eks_node_group_role.arn
}

