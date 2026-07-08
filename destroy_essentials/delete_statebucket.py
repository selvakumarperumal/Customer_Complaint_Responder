import boto3

BUCKET_NAME = 'ccr-tfstate-bucket-001-961445532924'
REGION = 'ap-south-1'

s3 = boto3.resource('s3', region_name=REGION)
client = boto3.client('s3', region_name=REGION)

bucket = s3.Bucket(BUCKET_NAME)

# 1. Delete all object versions + delete markers
bucket.object_versions.all().delete()

# 2. Abort any incomplete multipart uploads (can block bucket deletion)
paginator = client.get_paginator('list_multipart_uploads')
for page in paginator.paginate(Bucket=BUCKET_NAME):
    for upload in page.get('Uploads', []):
        client.abort_multipart_upload(
            Bucket=BUCKET_NAME,
            Key=upload['Key'],
            UploadId=upload['UploadId']
        )

# 3. Delete the bucket (I use Terraform to do this)
# bucket.delete()

print(f"Cleaned the bucket: {BUCKET_NAME}")