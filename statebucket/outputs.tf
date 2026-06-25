output "bucket_name" {
  description = "S3 bucket name for storing state files"
  value       = module.s3_bucket.s3_bucket_id
}
