output "server_ipv4" {
  description = "Public IPv4. Also what the A records point at."
  value       = hcloud_server.lab.ipv4_address
}

output "server_ipv6" {
  value = hcloud_server.lab.ipv6_address
}

output "hostnames" {
  value = [for h in var.hostnames : "${h}.${var.domain}"]
}

output "ssh" {
  description = "cloud-init takes a few minutes; /var/lib/cloud/obs-lab-ready appears when it is done."
  value       = "ssh lab@${hcloud_server.lab.ipv4_address}"
}

output "tunnel" {
  description = "Grafana, Prometheus and Alertmanager are firewalled off. Tunnel instead."
  value       = "ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093 lab@${hcloud_server.lab.ipv4_address}"
}
