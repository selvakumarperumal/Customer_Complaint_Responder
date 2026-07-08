# Destroy Essentials
This directory contains utility scripts to help clean up resources (such as ECR registry image contents and remote S3 terraform state bucket versions/multipart uploads) before running `terraform destroy`.

## Usage

Ensure you have your AWS credentials set up in your environment.

### 1. Clean ECR Repositories (delete images)
To empty the `poller` and `worker` ECR registries:
```bash
uv run delete_ecr_repo.py
```

### 2. Clean S3 State Bucket (delete versions/delete markers/multipart uploads)
To clean up the S3 state bucket:
```bash
uv run delete_statebucket.py
```
