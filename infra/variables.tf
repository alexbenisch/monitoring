variable "hcloud_token" {
  description = "Hetzner Cloud API token, Read & Write. From TF_VAR_hcloud_token."
  type        = string
  sensitive   = true
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
    cx32 = 4 vCPU / 8 GB / 80 GB, ~EUR 6.80/mo.

    Scenario 01 asks for 4 vCPU / 6 GB free, and kube-prometheus-stack alone
    reserves ~700 MB, so cx22 (2 vCPU / 4 GB) will thrash. Run the `hcloud`
    workflow to list what is actually orderable in your project.
  EOT
  type        = string
  default     = "cx32"
}

variable "location" {
  description = "nbg1, fsn1, hel1, ash, hil, sin. Keep it near the Object Storage bucket."
  type        = string
  default     = "nbg1"
}

variable "image" {
  type    = string
  default = "ubuntu-24.04"
}

variable "ssh_public_key" {
  description = <<-EOT
    Your SSH public key, verbatim. Public keys are not secrets, so this comes
    from a repo *variable* (SSH_PUBLIC_KEY), not a repo secret.
  EOT
  type        = string
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
