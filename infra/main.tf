locals {
  # `gh variable set NAME < file` stores the file's trailing newline too. The
  # Hetzner API is picky about a key with trailing whitespace, and it would
  # otherwise show up as a permanent diff on every plan.
  ssh_public_key = trimspace(var.ssh_public_key)
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

  # Rescale CPU and RAM only, leaving the disk at the size it already has.
  #
  # Hetzner cannot shrink a disk, so a rescale that grows it is a one-way
  # door: the server could never move back to a type with a smaller one.
  # Keeping the disk makes every future resize reversible, at the cost of not
  # getting the larger type's disk - which is irrelevant here, since 160 GB is
  # barely a third used.
  #
  # Changing server_type is an in-place rescale (the provider calls Hetzner's
  # change-type API); it is NOT a replacement. `location` and `image` are the
  # attributes that would destroy and recreate this server.
  keep_disk = true

  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.lab.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = local.ssh_public_key
    # indent() skips the first line, which is exactly what a YAML block scalar
    # needs: the template already supplies that line's indentation.
    minikube_unit = indent(6, file("${path.module}/files/minikube.service"))
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
