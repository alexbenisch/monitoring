#!/usr/bin/env bash
#
# Enable minikube's registry addon: the in-cluster registry that Kaniko pushes
# hello-java images to. Idempotent, and minikube remembers enabled addons
# across the restarts the systemd unit does.
#
# Run this on the lab host.
#
# Two names for the same registry, and which one to use depends on who asks:
#   push (Kaniko, inside a pod):  registry.kube-system.svc.cluster.local/hello-java
#   pull (the node's containerd): localhost:5000/hello-java
# The addon's registry-proxy DaemonSet is what makes localhost:5000 work on
# the node. It is plain HTTP; that is fine in a lab and nowhere else.

set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-obs-lab}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

command -v minikube >/dev/null || die "minikube not found"

log "enabling the registry addon on profile ${PROFILE}"
minikube -p "$PROFILE" addons enable registry >/dev/null

log "waiting for the registry"
kubectl -n kube-system rollout status deployment/registry --timeout=5m
kubectl -n kube-system rollout status daemonset/registry-proxy --timeout=5m

log "checking the registry API"
kubectl get --raw \
  "/api/v1/namespaces/kube-system/services/registry:80/proxy/v2/_catalog"
echo
