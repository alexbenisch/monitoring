terraform {
  # 1.10 is the floor: `use_lockfile` (S3-native state locking via conditional
  # writes) does not exist before it, and without it this backend has no locking
  # at all.
  required_version = ">= 1.10.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.69"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.25"
    }
  }
}
