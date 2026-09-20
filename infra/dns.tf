# v5 changed this: `data "cloudflare_zone"` now takes a zone_id, so it cannot
# look a zone up by name any more. The plural data source is how you go from a
# domain to an id.
data "cloudflare_zones" "lab" {
  name = var.domain
}

locals {
  zone_id = one(data.cloudflare_zones.lab.result).id

  # Proxied records must use ttl = 1 ("automatic"); Cloudflare rejects anything
  # else. 300 keeps the unproxied case re-pointable quickly.
  record_ttl = var.proxied ? 1 : 300
}

# v5 renamed cloudflare_record -> cloudflare_dns_record and value -> content.
resource "cloudflare_dns_record" "lab" {
  for_each = toset(var.hostnames)

  zone_id = local.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "A"
  content = hcloud_server.lab.ipv4_address
  ttl     = local.record_ttl
  proxied = var.proxied
  comment = "obs-lab, managed by terraform"
}

resource "cloudflare_dns_record" "lab_v6" {
  for_each = toset(var.hostnames)

  zone_id = local.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "AAAA"
  content = hcloud_server.lab.ipv6_address
  ttl     = local.record_ttl
  proxied = var.proxied
  comment = "obs-lab, managed by terraform"
}
