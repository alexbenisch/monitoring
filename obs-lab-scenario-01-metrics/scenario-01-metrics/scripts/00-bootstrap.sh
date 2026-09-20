#!/usr/bin/env bash
#
# Bring up minikube and install kube-prometheus-stack.
# Idempotent: safe to re-run.
#
# Usage: ./scripts/00-bootstrap.sh [--cpus N] [--memory MB] [--driver NAME]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

PROFILE="${MINIKUBE_PROFILE:-obs-lab}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-6144}"
DRIVER="${DRIVER:-docker}"
K8S_VERSION="${K8S_VERSION:-stable}"
RELEASE="kube-prom-stack"
MON_NS="monitoring"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpus)   CPUS="$2";   shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --driver) DRIVER="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for bin in minikube kubectl helm docker; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found in PATH"
done

# --- minikube -----------------------------------------------------------
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  log "minikube profile '$PROFILE' already running"
else
  log "starting minikube profile '$PROFILE' (${CPUS} cpu, ${MEMORY}MB, driver=${DRIVER})"
  minikube start \
    -p "$PROFILE" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --driver="$DRIVER" \
    --kubernetes-version="$K8S_VERSION" \
    --addons=metrics-server
fi

kubectl config use-context "$PROFILE"

# --- helm repo ----------------------------------------------------------
log "adding/updating the prometheus-community helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update prometheus-community >/dev/null

# --- kube-prometheus-stack ----------------------------------------------
# Pin the chart version for reproducibility once you know which one you want:
#   helm search repo prometheus-community/kube-prometheus-stack --versions | head
# then add: --version <x.y.z>
log "installing/upgrading ${RELEASE} into namespace ${MON_NS}"
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$MON_NS" \
  --create-namespace \
  --values "${ROOT_DIR}/helm/kube-prometheus-stack.values.yaml" \
  --wait \
  --timeout 15m

log "waiting for Prometheus and Grafana to be ready"
kubectl -n "$MON_NS" rollout status deploy/"${RELEASE}-grafana" --timeout=5m
kubectl -n "$MON_NS" wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus --timeout=5m

cat <<EOF

$(log "bootstrap complete")

  Namespace:  ${MON_NS}
  Grafana:    admin / obslab (anonymous viewer access is also enabled)

Next:
  ./scripts/10-deploy-app.sh
  ./scripts/port-forward.sh
EOF
