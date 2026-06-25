variable "aws_region" {
  description = "AWS region name"
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name_prefix" {
  description = "S3 bucket name prefix for Terraform state"
  type        = string
  default     = "ccr-tfstate-bucket-001"
}

variable "lock_table_name_prefix" {
  description = "DynamoDB table name prefix for Terraform state locking"
  type        = string
  default     = "ccr-tfstate-dynamodb-001"
}
