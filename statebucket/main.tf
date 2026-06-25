terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}



module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = "${var.bucket_name_prefix}-${data.aws_caller_identity.current.account_id}"
  acl    = "private"

  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  versioning = {
    enabled = true
  }
}

module "dynamodb_table" {
  source = "terraform-aws-modules/dynamodb-table/aws"

  name = "${var.lock_table_name_prefix}-${data.aws_caller_identity.current.account_id}"

  hash_key = "LockID"

  attributes = [
    { name = "LockID", type = "S" }
  ]

  billing_mode = "PAY_PER_REQUEST"

  tags = {
    Name = "${var.lock_table_name_prefix}-${data.aws_caller_identity.current.account_id}"
  }
}

