locals {
  # `gh variable set NAME < file` stores the file's trailing newline too. The
  # Hetzner API is picky about a key with trailing whitespace, and it would
  # otherwise show up as a permanent diff on every plan.
  ssh_public_key = trimspace(var.ssh_public_key)
}

# TEMPORARY. This key was uploaded to the project by hand before Terraform
# existed, and Hetzner enforces uniqueness on the fingerprint, so creating it
# again fails with 409 uniqueness_error. Adopt the existing object instead.
#
# Remove this block once the apply has run - import blocks are meant to be
# deleted after they have done their job, and a stale one breaks the next
# apply after a destroy, when id 130249897 no longer exists.
import {
  to = hcloud_ssh_key.admin
  id = "130249897"
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.server_name}-admin"
  public_key = local.ssh_public_key
}

resource "hcloud_firewall" "lab" {
  name = "${var.server_name}-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_ips
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = var.web_allowed_ips
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = var.web_allowed_ips
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Note what is NOT here: 3000 (Grafana), 9090 (Prometheus), 9093
  # (Alertmanager). Those stay closed and are reached over an SSH tunnel, as
  # scenario 01's README says. An unauthenticated Prometheus on a public IP is
  # a read of every metric you collect, and its /api/v1/admin endpoints can
  # delete series.
}

resource "hcloud_server" "lab" {
  name        = var.server_name
  image       = var.image
  server_type = var.server_type
  location    = var.location

  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.lab.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = local.ssh_public_key
  })

  labels = {
    project = "obs-lab"
    managed = "terraform"
  }

  lifecycle {
    # user_data only ever runs on first boot. Without this, editing cloud-init
    # silently recreates the server and everything on it.
    ignore_changes = [user_data]
  }
}
