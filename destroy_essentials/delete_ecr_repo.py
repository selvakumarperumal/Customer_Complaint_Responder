import boto3

REGION = 'ap-south-1'
REPOSITORIES = ['complaint-responder-ecr/poller', 'complaint-responder-ecr/worker']

ecr = boto3.client('ecr', region_name=REGION)

def get_all_image_ids(repo_name):
    """Fetch every image (tagged + untagged) in a repo, handling pagination."""
    paginator = ecr.get_paginator('list_images')
    image_ids = []
    for page in paginator.paginate(repositoryName=repo_name):
        image_ids.extend(page['imageIds'])
    return image_ids

def delete_images(repo_name, image_ids):
    """AWS limits batch_delete_image to 100 images per call, so chunk it."""
    for i in range(0, len(image_ids), 100):
        chunk = image_ids[i:i + 100]
        ecr.batch_delete_image(repositoryName=repo_name, imageIds=chunk)

for repo in REPOSITORIES:
    images = get_all_image_ids(repo)
    if images:
        delete_images(repo, images)
        print(f"Deleted {len(images)} images from {repo}")
    else:
        print(f"No images found in {repo}")