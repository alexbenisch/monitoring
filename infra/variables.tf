variable "hcloud_token" {
  description = "Hetzner Cloud API token, Read & Write. From TF_VAR_hcloud_token."
  type        = string
  sensitive   = true

  validation {
    # The provider enforces this anyway, but it fails after init has already
    # touched remote state. A truncated paste is the common case.
    condition     = length(var.hcloud_token) == 64
    error_message = "hcloud_token must be exactly 64 characters. Check the HCLOUD_TOKEN secret was not truncated when pasted."
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare scoped token: Zone:Read + DNS:Edit on the zone below."
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Cloudflare zone that already exists in the account."
  type        = string
  default     = "kubetest.uk"
}

variable "hostnames" {
  description = "Subdomains to point at the lab server. Keys become <key>.<domain>."
  type        = list(string)
  default     = ["app", "monitoring"]
}

variable "proxied" {
  description = <<-EOT
    Route the records through Cloudflare's proxy (orange cloud).

    Left false on purpose. Proxying only forwards HTTP/HTTPS on a fixed set of
    ports, which breaks SSH and the port-forwarded Grafana/Prometheus the
    scenarios rely on. The cost of false is that the server's real IP is public.
  EOT
  type        = bool
  default     = false
}

variable "server_name" {
  type    = string
  default = "obs-lab"
}

variable "server_type" {
  description = <<-EOT
    cpx42 = 8 vCPU / 16 GB / 320 GB, shared x86.

    Was cpx32 (4 vCPU / 8 GB) through scenarios 01 and 02. Scenario 05 adds a
    Jenkins controller plus an ephemeral build agent per build, which together
    peak around 7 GB on top of the ~4.3 GB the observability stack already
    uses - over the ceiling, and the kubelet evicts by usage, so Grafana and
    Prometheus would go first every time a build ran.

    Note the disk does NOT grow to 320 GB here: `keep_disk` is set on the
    server resource so the volume stays at 160 GB and the change stays
    reversible. Hetzner cannot shrink a disk.

    Confirmed orderable in nbg1, hel1 and sin - NOT fsn1, unlike cpx32.
    Availability is per-project and moves, so re-run the `hcloud` workflow
    with `server-types` before changing this.
  EOT
  type        = string
  default     = "cpx42"
}

variable "location" {
  description = "nbg1, fsn1, hel1, ash, hil, sin. Keep it near the Object Storage bucket."
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = <<-EOT
    TEMPORARY: pinned to snapshot 435320677, taken 2026-09-23 with scenarios
    01 and 02 deployed and hello-java running in `apps`.

    The lab host is destroyed overnight to avoid paying for it, and this is
    what makes coming back a single `apply` instead of a rebuild. Without it
    Terraform would create a blank ubuntu-24.04, run cloud-init, and leave the
    snapshot unused - the snapshot is only a backup if something is actually
    pointed at it.

    REVERT THIS to "ubuntu-24.04" once the lab is back up, and delete the
    snapshot. A snapshot id in version control goes stale the moment the
    snapshot is removed, and the failure then is a confusing "image not found"
    on an apply that used to work.

    Changing this forces a new server: image is ForceNew.
  EOT
  type        = string
  default     = "435320677"
}

variable "ssh_public_key" {
  description = <<-EOT
    Your SSH public key, verbatim. Public keys are not secrets, so this comes
    from a repo *variable* (SSH_PUBLIC_KEY), not a repo secret.

    `gh variable set SSH_PUBLIC_KEY < key.pub` keeps the file's trailing
    newline, so this is trimmed before use - see local.ssh_public_key.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) AAAA[0-9A-Za-z+/=]+", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key must be an OpenSSH public key (ssh-ed25519, ssh-rsa or ecdsa-sha2-nistp*). A private key, a .pem, or a raw GPG export will not work - use `gpg --export-ssh-key <keyid>` for a GPG auth subkey."
  }
}

variable "ssh_allowed_ips" {
  description = <<-EOT
    CIDRs allowed to reach port 22.

    Defaults to the whole internet because CI has no idea where you are. Narrow
    it to your own address if it is static - an open 22 on a public IP sees
    credential-stuffing within the hour.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "web_allowed_ips" {
  description = "CIDRs allowed to reach 80/443. Needed open for ACME HTTP-01."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
