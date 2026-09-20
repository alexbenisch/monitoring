# Hetzner Object Storage is S3-compatible (Ceph RGW), not S3. Every flag below
# exists to stop the AWS SDK doing something AWS-specific against an endpoint
# that has never heard of AWS.
#
# `bucket` and `endpoints` are deliberately absent: they are passed at init time
# with -backend-config from the repo variables TF_STATE_BUCKET and
# TF_STATE_ENDPOINT, so a public repo carries no account-shaped strings.
terraform {
  backend "s3" {
    key = "monitoring-lab/terraform.tfstate"

    # `region` is passed at init with -backend-config, derived from the
    # endpoint. It is NOT a dummy: Hetzner rejects CreateBucket with
    # LocationConstraintConflict unless the client region equals the bucket's
    # location, so "nbg1" endpoint means "nbg1" region.

    skip_credentials_validation = true # no AWS STS to call
    skip_region_validation      = true # "eu-central" is not an AWS region
    skip_requesting_account_id  = true # no IAM to ask who we are
    skip_metadata_api_check     = true # no EC2 instance metadata endpoint
    skip_s3_checksum            = true # Ceph RGW rejects the newer SDK checksums
    use_path_style              = true # bucket in the path, not the hostname

    # S3-native locking via conditional writes (If-None-Match). If `init` or
    # `plan` fails with 501 / NotImplemented on .tflock, delete this one line —
    # the workflow's `concurrency` group is the real serialisation guard.
    use_lockfile = true
  }
}
