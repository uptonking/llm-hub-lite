"""Ensure the Ladocs media bucket exists and is version-enabled.

Runs once per backend container start, before Django migrations. The bucket
holds document attachments and their version history, so versioning is part
of creation and is reasserted on every start (idempotent).
"""

import os
import sys

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError


def main() -> int:
    endpoint = os.environ["AWS_S3_ENDPOINT_URL"]
    access_key = os.environ["AWS_S3_ACCESS_KEY_ID"]
    secret_key = os.environ["AWS_S3_SECRET_ACCESS_KEY"]
    bucket = os.environ["AWS_STORAGE_BUCKET_NAME"]
    region = os.environ.get("AWS_S3_REGION_NAME") or "us-east-1"

    client = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name=region,
        config=Config(signature_version="s3v4", retries={"max_attempts": 3}),
    )

    try:
        client.head_bucket(Bucket=bucket)
        print(f"bucket {bucket} already exists")
    except ClientError:
        try:
            client.create_bucket(Bucket=bucket)
            print(f"bucket {bucket} created")
        except ClientError as error:
            # A concurrent first boot may have won the race.
            code = error.response.get("Error", {}).get("Code", "")
            if code not in ("BucketAlreadyExists", "BucketAlreadyOwnedByYou"):
                raise

    client.put_bucket_versioning(
        Bucket=bucket,
        VersioningConfiguration={"Status": "Enabled"},
    )
    print(f"bucket {bucket} versioning enabled")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BotoCoreError, ClientError, KeyError) as error:
        print(f"bootstrap_s3: {error}", file=sys.stderr)
        sys.exit(1)
