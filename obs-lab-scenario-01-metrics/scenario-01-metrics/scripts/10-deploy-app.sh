#!/usr/bin/env bash
#
# Build the demoapp image straight into the minikube node and apply the
# manifests. Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

PROFILE="${MINIKUBE_PROFILE:-obs-lab}"
IMAGE="obs-lab/demoapp"
TAG="${TAG:-1.0.0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "building ${IMAGE}:${TAG}"
docker build -t "${IMAGE}:${TAG}" "${ROOT_DIR}/app"

log "loading the image into minikube profile '${PROFILE}'"
# Loading beats pushing to a registry for a lab, and beats `minikube docker-env`
# because it works the same way with the containerd runtime.
minikube image load "${IMAGE}:${TAG}" -p "$PROFILE"

log "applying manifests"
kubectl apply -k "${ROOT_DIR}/k8s"

log "waiting for the rollout"
kubectl -n demo rollout status deploy/demoapp --timeout=3m
kubectl -n demo rollout status deploy/loadgen --timeout=3m

cat <<'EOF'

Deployed. Give Prometheus ~30s to discover the target, then check:

  kubectl -n demo get pods
  kubectl -n monitoring port-forward svc/kube-prom-stack-prometheus 9090:9090
  # -> http://localhost:9090/targets  (look for serviceMonitor/demo/demoapp/0)

EOF
