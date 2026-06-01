variable "name_prefix" {
    description = "Prefix for naming AWS resources (Name of the Cluster)"
    type        = string
}

variable "vpc_cidr" {
    description = "CIDR block for the VPC"
    type        = string
    default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
    description = "List of CIDR blocks for public subnets"
    type        = list(string)
    default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
    description = "List of CIDR blocks for private subnets"
    type        = list(string)
    default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "availability_zones" {
    description = "List of availability zones for subnets"
    type        = list(string)
    default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

variable "enable_nat_gateway" {
    description = "Whether to create a NAT Gateway for private subnets"
    type        = bool
    default     = true
}

variable "single_nat_gateway" {
    description = "Whether to use a single NAT Gateway for all private subnets"
    type        = bool
    default     = true
}

variable "private_subnet_tags" {
    description = "Tags to apply to private subnets"
    type        = map(string)
    default     = {}
}

variable "public_subnet_tags" {
    description = "Tags to apply to public subnets"
    type        = map(string)
    default     = {}
}

variable "tags" {
    description = "Tags to apply to all resources"
    type        = map(string)
    default     = {}
}