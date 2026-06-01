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

  # Uncomment to use S3 remote state backend:
  # backend "s3" {
  #   bucket         = "<your-tfstate-bucket>"
  #   key            = "ccr/terraform.tfstate"
  #   region         = "<your-region>"
  #   encrypt        = true
  #   dynamodb_table = "<your-lock-table>"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
